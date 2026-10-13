import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/device_pairing.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/phone_sign_in_panel.dart';
import 'package:onyx/screens/settings/tv_link_scanner_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/tv_link.dart';

/// A server that hands out pairings and answers polls from a script.
class _PairingServer extends ApiClient {
  final List<DevicePairingStatus> answers;
  int starts = 0;
  int polls = 0;

  _PairingServer(this.answers);

  @override
  Future<DevicePairing> startDevicePairing({required String deviceName}) async {
    starts++;
    return DevicePairing(
      deviceCode: 'device-$starts',
      userCode: 'ABCDEFG$starts',
      expiresIn: const Duration(minutes: 5),
      pollInterval: const Duration(seconds: 2),
    );
  }

  @override
  Future<DevicePairingStatus> pollDevicePairing(String deviceCode) async {
    polls++;
    return answers.isEmpty
        ? const DevicePairingStatus(state: DevicePairingState.pending)
        : answers.removeAt(0);
  }
}

/// A link listener with no socket behind it.
class _FakeLinkSession implements TvLinkSession {
  /// Null reproduces a device with no usable network address.
  final TvLinkOffer? offer;

  final Completer<TvLinkPayload> _completer = Completer<TvLinkPayload>();

  _FakeLinkSession(this.offer);

  @override
  Future<TvLinkOffer?> start({required String deviceName}) async => offer;

  @override
  Future<TvLinkPayload> get linked => _completer.future;

  @override
  Future<void> stop() async {}

  void deliver(TvLinkPayload payload) => _completer.complete(payload);
}

const _offer = TvLinkOffer(
  url: 'http://192.168.1.42:41234/link?c=abcdef&n=Bureau&a=10.0.0.4',
  host: '192.168.1.42',
  port: 41234,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  Future<AuthProvider> pumpPanel(
    WidgetTester tester,
    ApiClient apiClient, {
    String? serverUrl = 'http://192.168.1.50:8080',
    TvLinkSession? linkSession,
  }) async {
    final auth = AuthProvider(apiClient);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiClient),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PhoneSignInPanel(
              serverUrl: serverUrl,
              // Never the real listener: it binds a socket.
              directLink: linkSession != null,
              createLinkSession:
                  linkSession == null ? null : () => linkSession,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return auth;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('shows the pairing as a QR and its code in clear',
      (tester) async {
    final server = _PairingServer([]);
    await server.setConnection('http://192.168.1.50:8080');
    await pumpPanel(tester, server);

    expect(server.starts, 1);
    expect(find.text('Code : ABCD-EFG1'), findsOneWidget);
    // The phone's scanner reads what the QR carries, so its shape is the
    // contract between the two screens.
    expect(PairingLink.parse(server.devicePairingLink('ABCDEFG1'))?.code,
        'ABCDEFG1');
    expect(find.byType(QrImageView), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an approval signs this screen in', (tester) async {
    final server = _PairingServer([
      const DevicePairingStatus(state: DevicePairingState.pending),
      DevicePairingStatus(
        state: DevicePairingState.approved,
        token: 'session-token',
        user: User(id: 7, username: 'mathis'),
      ),
    ]);
    await server.setConnection('http://192.168.1.50:8080');
    final auth = await pumpPanel(tester, server);

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(auth.isAuthenticated, isFalse, reason: 'still pending');

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.currentUser?.username, 'mathis');
    expect(server.baseUrl, 'http://192.168.1.50:8080');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an expired code is replaced by a fresh one', (tester) async {
    final server = _PairingServer([
      const DevicePairingStatus(state: DevicePairingState.expired),
    ]);
    await server.setConnection('http://192.168.1.50:8080');
    await pumpPanel(tester, server);
    expect(find.text('Code : ABCD-EFG1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await settle(tester);

    expect(server.starts, 2);
    expect(find.text('Code : ABCD-EFG2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('without a server that answers, says so instead of spinning',
      (tester) async {
    final server = _PairingServer([]);
    await pumpPanel(tester, server, serverUrl: null);

    expect(server.starts, 0);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('adresse du serveur'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an app offers itself, with no server address at all',
      (tester) async {
    final server = _PairingServer([]);
    await pumpPanel(tester, server,
        serverUrl: null, linkSession: _FakeLinkSession(_offer));

    // The regression this replaces: the QR used to wait for the address field.
    expect(server.starts, 0);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('adresse du serveur'), findsNothing);
    expect(find.textContaining('même réseau'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a delivery brings the server and signs this screen in',
      (tester) async {
    final server = _PairingServer([]);
    final session = _FakeLinkSession(_offer);
    final auth =
        await pumpPanel(tester, server, serverUrl: null, linkSession: session);

    session.deliver(TvLinkPayload(
      serverUrl: 'http://192.168.1.50:8080',
      token: 'session-token',
      user: User(id: 7, username: 'mathis'),
    ));
    await settle(tester);

    expect(server.baseUrl, 'http://192.168.1.50:8080');
    expect(auth.isAuthenticated, isTrue);
    expect(auth.currentUser?.username, 'mathis');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an app with no network falls back to the server pairing',
      (tester) async {
    final server = _PairingServer([]);
    await server.setConnection('http://192.168.1.50:8080');
    await pumpPanel(tester, server, linkSession: _FakeLinkSession(null));
    await settle(tester);

    expect(server.starts, 1);
    expect(find.text('Code : ABCD-EFG1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('TvOffer.parse', () {
    test('lists the address in the QR first, then the alternates', () {
      final offer = TvOffer.parse(_offer.url);
      expect(offer?.code, 'abcdef');
      expect(offer?.deviceName, 'Bureau');
      expect(offer?.endpoints.map((uri) => uri.toString()), [
        'http://192.168.1.42:41234/link',
        'http://10.0.0.4:41234/link',
      ]);
    });

    test('an alternate can only be a bare address', () {
      final offer = TvOffer.parse(
          'http://192.168.1.42:41234/link?c=abcdef&a=evil.example.com,10.0.0.4:80,10.0.0.5');
      expect(offer?.endpoints.map((uri) => uri.host),
          ['192.168.1.42', '10.0.0.5']);
    });
  });

  group('PairingLink.parse', () {
    test('reads the code and the issuing server', () {
      final link = PairingLink.parse('https://onyx.example.com/?tv=abcd-efgh');
      expect(link?.code, 'ABCDEFGH');
      expect(link?.origin, 'https://onyx.example.com');
    });

    test('leaves a television offer and foreign codes alone', () {
      expect(
          PairingLink.parse('http://192.168.1.42:41234/link?c=abcdef&n=Salon'),
          isNull);
      expect(PairingLink.parse('https://example.com/?tv=SHORT'), isNull);
      expect(PairingLink.parse('WIFI:S:home;T:WPA;P:secret;;'), isNull);
    });
  });
}
