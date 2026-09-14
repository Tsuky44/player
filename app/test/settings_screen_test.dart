import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_activity.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/settings/settings_screen.dart';
import 'package:onyx/services/api_client.dart';

class _FakeApi extends ApiClient {
  int statsCalls = 0;

  @override
  String get baseUrl => 'http://maison.local';

  @override
  Future<User> getMe() async => throw Exception('hors ligne');

  @override
  Future<PlaybackStats> getMyPlaybackStats({int days = 30}) async =>
      _stats(topUsers: const []);

  @override
  Future<PlaybackStats> getPlaybackStats({int days = 30, int? userId}) async {
    statsCalls++;
    return _stats(topUsers: [
      {'key': '1', 'label': 'mathis', 'plays': 3, 'watched_seconds': 7200},
    ]);
  }

  @override
  Future<List<User>> getUsers() async => [User(id: 1, username: 'mathis')];

  @override
  Future<List<ConnectedDevice>> getMyDevices() async => [
        ConnectedDevice.fromJson({
          'id': 1,
          'user_id': 1,
          'username': 'mathis',
          'device_name': 'Salon',
          'client': 'Android TV 1.4.2',
          'last_seen_at': DateTime.now().toUtc().toIso8601String(),
          'is_current': true,
        }),
      ];

  PlaybackStats _stats({required List<Map<String, Object>> topUsers}) =>
      PlaybackStats.fromJson({
        'days': 30,
        'totals': {
          'plays': 3,
          'watched_seconds': 7200,
          'active_users': 1,
          'movies': 0,
          'episodes': 3,
        },
        'daily': [
          for (var i = 0; i < 30; i++)
            {
              'date': '2026-09-${(i + 1).toString().padLeft(2, '0')}',
              'plays': i % 3,
              'watched_seconds': i * 60
            },
        ],
        'hour_of_day': List.filled(24, 0),
        'top_users': topUsers,
        'top_media': [
          {
            'key': 'show:Severance',
            'label': 'Severance',
            'secondary': '3 épisode(s)',
            'media_type': 'show',
            'plays': 3,
            'watched_seconds': 7200,
          },
        ],
        'clients': [
          {
            'key': 'Android TV',
            'label': 'Android TV',
            'plays': 3,
            'watched_seconds': 7200
          },
        ],
        'play_methods': [
          {
            'key': 'direct',
            'label': 'direct',
            'plays': 2,
            'watched_seconds': 5000
          },
          {
            'key': 'transcode',
            'label': 'transcode',
            'plays': 1,
            'watched_seconds': 2200
          },
        ],
      });
}

class _FakeAuth extends AuthProvider {
  _FakeAuth(super.api, this._permissions);

  final Permissions _permissions;

  @override
  User? get currentUser =>
      User(id: 1, username: 'mathis', permissions: _permissions);

  @override
  Permissions get permissions => _permissions;
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

  Future<_FakeApi> pump(WidgetTester tester,
      {required double width, required Permissions permissions}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeApi();
    await api.initialize();
    final auth = _FakeAuth(api, permissions);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('un membre ne voit que son espace, avec ses appareils',
      (tester) async {
    await pump(tester, width: 1100, permissions: const Permissions());

    expect(find.text('Mon espace'), findsOneWidget);
    expect(find.text('Administration'), findsNothing);
    expect(find.text('Tableau de bord'), findsNothing);
    // La page ouverte d'emblée est le compte : stats perso et appareils.
    expect(find.text('Salon'), findsOneWidget);
    expect(find.text('Cet appareil'), findsWidgets);
    expect(find.text('Temps de visionnage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'un administrateur ouvre les statistiques depuis la barre latérale',
      (tester) async {
    final api = await pump(tester, width: 1100, permissions: Permissions.all);

    expect(find.text('Administration'), findsOneWidget);
    await tester.tap(find.text('Statistiques'));
    await tester.pumpAndSettle();

    expect(api.statsCalls, 1);
    expect(find.text('Titres les plus regardés'), findsOneWidget);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('Transcodage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sur téléphone, les catégories sont une liste qui ouvre une page',
      (tester) async {
    await pump(tester, width: 380, permissions: Permissions.all);

    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.text('Mon compte'));
    await tester.pumpAndSettle();

    expect(find.text('Salon'), findsOneWidget);
    expect(find.text('Mes appareils connectés'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
