import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/servers_screen.dart';
import 'package:onyx/services/api_client.dart';

class _FakeApiClient extends ApiClient {
  final Map<String, User> profiles = {};

  @override
  Future<User> getMe() async {
    final user = profiles[baseUrl];
    if (user == null) throw Exception('aucun profil pour $baseUrl');
    return user;
  }
}

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

  Future<(_FakeApiClient, AuthProvider)> pumpServers(WidgetTester tester) async {
    final api = _FakeApiClient();
    await api.initialize();
    api.profiles['http://maison.local'] =
        User(id: 1, username: 'mathis');
    api.profiles['http://paul.local'] = User(id: 7, username: 'mathis');
    await api.rememberSession(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      token: 'b',
    );
    await api.rememberSession(
      serverUrl: 'http://maison.local',
      username: 'mathis',
      token: 'a',
    );

    final auth = AuthProvider(api);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: const MaterialApp(home: ServersScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return (api, auth);
  }

  testWidgets('les deux serveurs sont là, un seul marqué actif', (tester) async {
    final (_, auth) = await pumpServers(tester);

    expect(find.text('maison.local'), findsOneWidget);
    expect(find.text('paul.local'), findsOneWidget);
    expect(find.textContaining('serveur actif'), findsOneWidget);
    expect(auth.activeServer?.url, 'http://maison.local');
  });

  testWidgets('toucher l’autre serveur bascule dessus', (tester) async {
    final (_, auth) = await pumpServers(tester);

    await tester.tap(find.text('paul.local'));
    await tester.pumpAndSettle();

    expect(auth.activeServer?.url, 'http://paul.local');
    expect(auth.currentUser?.id, 7,
        reason: 'l’identité est relue au serveur d’arrivée');
  });
}
