import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/device_pairing.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/tv_login_screen.dart';
import 'package:onyx/services/api_client.dart';

/// An [ApiClient] whose pairing call answers per address.
///
/// Everything else — the base URL, `setConnection`, the link the QR encodes —
/// is the real thing, because the behaviour under test is which address the
/// screen ends up talking to and what it renders when that fails.
class _FakeApiClient extends ApiClient {
  /// Addresses that have a server behind them. Anything else is refused.
  final Set<String> reachable;

  final List<String> attempts = [];

  _FakeApiClient(this.reachable);

  @override
  Future<DevicePairing> startDevicePairing({required String deviceName}) async {
    attempts.add(baseUrl);
    if (!reachable.contains(baseUrl)) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/api/auth/device/start'),
        reason: 'SocketException: Connection refused',
      );
    }
    return const DevicePairing(
      deviceCode: 'device-secret',
      userCode: 'ABCD2345',
      expiresIn: Duration(minutes: 5),
      pollInterval: Duration(seconds: 2),
    );
  }

  @override
  Future<DevicePairingStatus> pollDevicePairing(String deviceCode) async =>
      const DevicePairingStatus(state: DevicePairingState.pending);
}

Widget _harness(ApiClient apiClient, {Future<String?> Function()? discover}) {
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
    ],
    child: MaterialApp(home: TvLoginScreen(discoverServer: discover)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Switching servers clears the stored token, which reaches for the keychain.
    // Unmocked, that channel never answers in a test and the pairing hangs
    // half-open — the screen would sit on a spinner for reasons that have
    // nothing to do with the code under test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  /// Mounts the screen at television size and lets the pairing settle. The
  /// screen opens its pairing from a post-frame callback, so the first pump
  /// only starts it.
  Future<void> pumpTv(WidgetTester tester, Widget app) async {
    // The 800x600 default would exercise the narrow fallback; the layout under
    // test goes side by side above 820.
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app);
    // Several short frames rather than pumpAndSettle: the spinner never settles,
    // and the pairing resolves across a handful of awaits.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Unmounts before the test ends so the poll and countdown timers are
  /// cancelled in dispose rather than flagged as still pending.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('renders the QR once the pairing is open', (tester) async {
    final apiClient = _FakeApiClient({'http://tv.local:8080'});
    await apiClient.setConnection('http://tv.local:8080');

    await pumpTv(tester, _harness(apiClient));

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('ABCD-2345'), findsOneWidget);

    await unmount(tester);
  });

  // The regression this file exists for: the unreachable-server branch was
  // shadowed by the "no pairing yet" spinner, so a television that could not
  // reach a server showed a loading ring forever — no message, no retry, and no
  // way to enter an address.
  testWidgets('shows the error, not a spinner, when nothing answers',
      (tester) async {
    final apiClient = _FakeApiClient(const {});
    await apiClient.setConnection('http://dead.local:8080');

    await pumpTv(tester, _harness(apiClient, discover: () async => null));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Serveur injoignable'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.text("Saisir l'adresse"), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('says so when the sweep finds nothing at all', (tester) async {
    final apiClient = _FakeApiClient(const {});

    await pumpTv(tester, _harness(apiClient, discover: () async => null));

    expect(find.textContaining('Aucun serveur Onyx'), findsOneWidget);
    // A default address was never chosen, so it is not worth ten seconds of
    // connect timeout before the sweep.
    expect(apiClient.attempts, isEmpty);

    await unmount(tester);
  });

  testWidgets('falls back to the discovered server when the address is dead',
      (tester) async {
    final apiClient = _FakeApiClient({'http://192.168.1.50:8080'});
    await apiClient.setConnection('http://dead.local:8080');

    await pumpTv(
      tester,
      _harness(apiClient, discover: () async => 'http://192.168.1.50:8080'),
    );

    expect(find.byType(QrImageView), findsOneWidget);
    expect(apiClient.baseUrl, 'http://192.168.1.50:8080');
    expect(apiClient.attempts,
        ['http://dead.local:8080', 'http://192.168.1.50:8080']);

    await unmount(tester);
  });
}
