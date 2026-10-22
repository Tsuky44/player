import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/models/profile_avatar.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/add_user_screen.dart';
import 'package:onyx/screens/auth/avatar_picker_screen.dart';
import 'package:onyx/screens/auth/user_choice_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/theme/profile_avatars.dart';

/// Les images de profil, le choix d'une personne en changeant de serveur, et
/// l'ajout de quelqu'un par son seul identifiant. Voir ADR-0078.

class _FakeApiClient extends ApiClient {
  /// Les avatars de galerie demandés, par compte.
  final List<String> presets = [];

  @override
  Future<User> getMe() async {
    final active = servers.active!;
    return User(
      id: active.userId ?? 1,
      username: active.username,
      avatar: active.avatar ?? '',
    );
  }

  @override
  Future<User> signInAt({
    required String serverUrl,
    required String username,
    required String password,
    bool activate = false,
  }) async {
    final user = User(id: 9, username: username);
    await rememberSession(
      serverUrl: serverUrl,
      username: username,
      token: 'jeton-$username',
      userId: user.id,
      activate: activate,
    );
    return user;
  }

  /// Ce que fait le vrai appel : le serveur rend le compte, et le carnet
  /// retient la nouvelle image.
  @override
  Future<User> setAvatarPreset(ServerAccount account, String? key) async {
    presets.add('${account.username}:${key ?? ''}');
    final avatar = key == null ? '' : 'preset:$key';
    await servers.setAvatar(account.id, avatar);
    return User(
        id: account.userId ?? 1, username: account.username, avatar: avatar);
  }

  @override
  Future<void> refreshAccountLinks() async {}
}

Future<void> _settle(AuthProvider auth) async {
  for (var i = 0; i < 200 && (auth.isInitializing || auth.isLoading); i++) {
    await Future<void>.delayed(Duration.zero);
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

  /// Actif sur « bureau », avec Mathis et Léa sur « maison ».
  Future<_FakeApiClient> deviceWithAFamilyElsewhere() async {
    final api = _FakeApiClient();
    await api.initialize();
    for (final (url, name, id) in [
      ('http://maison.local', 'mathis', 1),
      ('http://maison.local', 'lea', 2),
      ('http://bureau.local', 'mathis', 7),
    ]) {
      await api.rememberSession(
        serverUrl: url,
        username: name,
        token: 'jeton-$name-$id',
        userId: id,
      );
    }
    return api;
  }

  Widget app(_FakeApiClient api, AuthProvider auth, Widget home) =>
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(home: home),
      );

  group('l’image décrite par le serveur', () {
    for (final (raw, expected) in [
      ('', InitialAvatar),
      (null, InitialAvatar),
      ('preset:cat', PresetAvatar),
      ('photo:1729600000000', PhotoAvatar),
      ('preset:', InitialAvatar),
      ('hologram:3', InitialAvatar),
    ]) {
      test('« $raw » se lit $expected', () {
        expect(ProfileAvatar.parse(raw).runtimeType, expected);
      });
    }

    test('chaque avatar de la galerie a une clé que le serveur accepte', () {
      final keys = ProfileAvatars.gallery.map((p) => p.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'une clé par avatar');
      for (final key in keys) {
        expect(RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(key), isTrue,
            reason: '$key serait refusée par PUT /api/me/avatar');
      }
    });
  });

  group('carnet', () {
    test(
        'un autre serveur ne compte qu’une fois, quel que soit son nombre '
        'de comptes', () async {
      final api = await deviceWithAFamilyElsewhere();

      final others = api.servers.otherServers(api.servers.active);

      expect(others.map((a) => a.url), ['http://maison.local']);
    });

    test('l’image retenue survit à une reconnexion', () async {
      final api = await deviceWithAFamilyElsewhere();
      final bureau = api.servers.active!;
      await api.servers.setAvatar(bureau.id, 'preset:rocket');

      await api.rememberSession(
        serverUrl: bureau.url,
        username: bureau.username,
        token: 'nouveau-jeton',
      );

      expect(api.servers.active!.avatar, 'preset:rocket');
    });

    test('le profil relu au serveur met l’image du carnet à jour', () async {
      final api = await deviceWithAFamilyElsewhere();

      await api
          .cacheProfile(User(id: 7, username: 'mathis', avatar: 'preset:cat'));

      expect(api.servers.active!.avatar, 'preset:cat');
    });
  });

  testWidgets(
      'changer pour un serveur à plusieurs personnes demande qui '
      'regarde là-bas', (tester) async {
    final api = await tester.runAsync(deviceWithAFamilyElsewhere);
    final auth = AuthProvider(api!, startupRetryPauses: const []);
    await tester.runAsync(() => _settle(auth));
    final maison = api.servers.accountForUrl('http://maison.local')!;

    await tester.pumpWidget(
        app(api, auth, UserChoiceScreen(serverAccountId: maison.id)));
    await tester.pump();

    expect(find.text('maison.local'), findsOneWidget);
    expect(find.bySemanticsLabel('Regarder en tant que lea'), findsOneWidget);
    expect(find.bySemanticsLabel('Regarder en tant que mathis'), findsOneWidget,
        reason: 'le Mathis de maison, pas celui du bureau');

    await tester.tap(find.bySemanticsLabel('Regarder en tant que lea'));
    await tester.runAsync(() => _settle(auth));

    expect(auth.activeServer?.url, 'http://maison.local');
    expect(auth.activeServer?.username, 'lea');
  });

  testWidgets(
      '« Gérer les profils » mène au choix de l’image, qui part au '
      'serveur du compte', (tester) async {
    final api = await tester.runAsync(deviceWithAFamilyElsewhere);
    final auth = AuthProvider(api!, startupRetryPauses: const []);
    await tester.runAsync(() => _settle(auth));
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await tester.pumpWidget(
        app(api, auth, UserChoiceScreen(serverAccountId: maison.id)));
    await tester.pump();

    await tester.tap(find.text('Gérer les profils'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Changer l’image de lea'));
    await tester.pumpAndSettle();
    expect(find.byType(AvatarPickerScreen), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Avatar 1'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(api.presets, ['lea:${ProfileAvatars.gallery.first.key}']);
    expect(
        api.servers
            .usersOf(maison.id)
            .firstWhere((a) => a.username == 'lea')
            .avatar,
        'preset:${ProfileAvatars.gallery.first.key}');
    expect(find.byType(AvatarPickerScreen), findsNothing,
        reason: 'un choix se suffit : retour à « Qui regarde ? »');
  });

  testWidgets(
      'ajouter quelqu’un ne demande que son identifiant et son mot '
      'de passe', (tester) async {
    final api = await tester.runAsync(deviceWithAFamilyElsewhere);
    final auth = AuthProvider(api!, startupRetryPauses: const []);
    await tester.runAsync(() => _settle(auth));
    final maison = api.servers.accountForUrl('http://maison.local')!;
    ServerAccount? added;
    await tester.pumpWidget(app(
      api,
      auth,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            added = await Navigator.of(context).push<ServerAccount>(
              MaterialPageRoute(builder: (_) => AddUserScreen(server: maison)),
            );
          },
          child: const Text('ouvrir'),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsNWidgets(2),
        reason: 'pas d’adresse à taper : c’est ce serveur-ci');
    await tester.enterText(find.byType(TextFormField).first, 'zoe');
    await tester.enterText(find.byType(TextFormField).last, 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.runAsync(() => _settle(auth));
    await tester.pumpAndSettle();

    expect(added?.username, 'zoe');
    expect(added?.url, 'http://maison.local');
  });
}
