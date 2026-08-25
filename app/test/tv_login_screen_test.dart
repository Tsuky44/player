import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/tv_login_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/tv_link.dart';

/// A link listener with no socket behind it.
///
/// The screen's whole job is what it does with an offer and with a delivery, so
/// the transport is the one part a widget test should not have.
class _FakeLinkSession implements TvLinkSession {
  /// Null reproduces a television with no usable network address.
  final TvLinkOffer? offer;

  final Completer<TvLinkPayload> _completer = Completer<TvLinkPayload>();

  int starts = 0;
  bool stopped = false;

  _FakeLinkSession(this.offer);

  @override
  Future<TvLinkOffer?> start({required String deviceName}) async {
    starts++;
    return offer;
  }

  @override
  Future<TvLinkPayload> get linked => _completer.future;

  @override
  Future<void> stop() async => stopped = true;

  void deliver(TvLinkPayload payload) => _completer.complete(payload);
}

const _offer = TvLinkOffer(
  url: 'http://192.168.1.42:41234/link?c=abcdef&n=Salon',
  host: '192.168.1.42',
  port: 41234,
);

Widget _harness(ApiClient apiClient, TvLinkSession session) {
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
    ],
    child: MaterialApp(
      home: TvLoginScreen(createLinkSession: () => session),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Switching servers clears the stored token, which reaches for the keychain.
    // Unmocked, that channel never answers in a test and the screen hangs
    // half-open — for reasons that have nothing to do with the code under test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  /// Mounts the screen at television size and lets the offer settle. The screen
  /// opens its listener from a post-frame callback, so the first pump only
  /// starts it.
  Future<void> pumpTv(WidgetTester tester, Widget app) async {
    // The 800x600 default would exercise the narrow fallback; the layout under
    // test goes side by side above 820.
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app);
    // Several short frames rather than pumpAndSettle: the spinner never
    // settles, and the offer resolves across a handful of awaits.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('renders the television own offer as a QR', (tester) async {
    final apiClient = ApiClient();
    final session = _FakeLinkSession(_offer);

    await pumpTv(tester, _harness(apiClient, session));

    // The code carries an address to this television, not to a server. That is
    // the point of the flow: there is no server address here yet, and the line
    // under the instructions shows whose address it is.
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('192.168.1.42'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('the screen never asks for a server address', (tester) async {
    final apiClient = ApiClient();

    await pumpTv(tester, _harness(apiClient, _FakeLinkSession(_offer)));

    // The regression this replaces: every path through the old screen ended at
    // "type the IP with a D-pad" when discovery came up empty. There is no
    // field to type into any more, and nothing that opens one.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Changer de serveur'), findsNothing);
    expect(find.text("Saisir l'adresse"), findsNothing);
    // The password form stays, for the first account on a pristine server.
    expect(find.text('Utiliser un mot de passe'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('shows the error and a retry when the TV has no network',
      (tester) async {
    final apiClient = ApiClient();
    final session = _FakeLinkSession(null);

    await pumpTv(tester, _harness(apiClient, session));

    // Not a spinner: a television that cannot offer anything has to say so and
    // give the user something to press.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('réseau'), findsWidgets);
    expect(find.text('Réessayer'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a delivery points the client at the server and signs in',
      (tester) async {
    final apiClient = ApiClient();
    final session = _FakeLinkSession(_offer);
    late AuthProvider auth;

    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiClient),
          ChangeNotifierProvider(create: (_) {
            auth = AuthProvider(apiClient);
            return auth;
          }),
        ],
        child: MaterialApp(
          home: TvLoginScreen(createLinkSession: () => session),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    session.deliver(TvLinkPayload(
      serverUrl: 'http://192.168.1.50:8080',
      token: 'session-token',
      user: User(id: 7, username: 'mathis'),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The address before the session: the token is only good on that host, and
    // adopting it against the wrong one authenticates nothing.
    expect(apiClient.baseUrl, 'http://192.168.1.50:8080');
    expect(auth.isAuthenticated, isTrue);
    expect(auth.currentUser?.username, 'mathis');
    expect(find.text('Compte connecté'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('retry opens a fresh offer', (tester) async {
    final apiClient = ApiClient();
    final session = _FakeLinkSession(null);

    await pumpTv(tester, _harness(apiClient, session));
    expect(session.starts, 1);

    await tester.tap(find.text('Réessayer'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(session.starts, 2);
    // The spent listener is closed rather than left holding a socket on a
    // living-room network.
    expect(session.stopped, isTrue);

    await unmount(tester);
  });
}
