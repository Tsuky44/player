import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/user_choice_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/server_registry.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';

/// Plusieurs personnes du même serveur sur un appareil partagé, et « Qui
/// regarde ? » pour passer de l'une à l'autre. Voir ADR-0078.

/// Un serveur qui rend le profil du compte actif, et compte les demandes.
class _FakeApiClient extends ApiClient {
  final List<String> meCalls = [];

  @override
  Future<User> getMe() async {
    final active = servers.active!;
    meCalls.add(active.username);
    return _user(active.username, id: active.userId ?? 1);
  }

  /// Ce que fait la vraie connexion par mot de passe, sans réseau : la
  /// session entre au carnet, active ou non.
  @override
  Future<User> signInAt({
    required String serverUrl,
    required String username,
    required String password,
    bool activate = false,
  }) async {
    final user = _user(username, id: 3);
    await rememberSession(
      serverUrl: serverUrl,
      username: user.username,
      token: 'jeton-$username',
      userId: user.id,
      activate: activate,
    );
    return user;
  }

  @override
  Future<void> refreshAccountLinks() async {}
}

User _user(String username, {int id = 1}) => User(
      id: id,
      username: username,
      permissions: const Permissions(requestMedia: true),
    );

/// L'auto-connexion part du constructeur ; on attend qu'elle retombe.
Future<void> _settle(AuthProvider auth) async {
  for (var i = 0; i < 200 && auth.isInitializing; i++) {
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

  /// La télévision du salon : Mathis et Léa sur « maison », actif sur Léa.
  Future<_FakeApiClient> sharedTelevision() async {
    final api = _FakeApiClient();
    await api.initialize();
    await api.rememberSession(
      serverUrl: 'http://maison.local',
      username: 'mathis',
      token: 'jeton-mathis',
      userId: 1,
    );
    await api.rememberSession(
      serverUrl: 'http://maison.local',
      username: 'lea',
      token: 'jeton-lea',
      userId: 2,
    );
    return api;
  }

  group('carnet', () {
    test('deux personnes du même serveur ont chacune leur compte', () async {
      final api = await sharedTelevision();

      expect(api.servers.accounts.map((a) => a.username), ['mathis', 'lea']);
      expect(await api.servers.tokenFor(api.servers.active!.id), 'jeton-lea');
    });

    test('les utilisateurs d’un serveur ne comptent pas ceux d’un autre',
        () async {
      final api = await sharedTelevision();
      await api.rememberSession(
        serverUrl: 'http://paul.local',
        username: 'mathis',
        token: 'jeton-paul',
        activate: false,
      );
      final lea = api.servers.active!;

      expect(api.servers.usersOf(lea.id).map((a) => a.username),
          ['mathis', 'lea']);
    });

    test('le même serveur se reconnaît à son identité malgré deux adresses',
        () {
      const local = ServerAccount(
          id: 'x', url: 'http://192.168.1.2', username: 'a', serverId: 's1');
      const remote = ServerAccount(
          id: 'y', url: 'https://maison.org', username: 'b', serverId: 's1');
      const other = ServerAccount(
          id: 'z', url: 'http://192.168.1.2', username: 'c', serverId: 's2');

      expect(ServerRegistry.sameServer(local, remote), isTrue);
      expect(ServerRegistry.sameServer(local, other), isFalse);
    });
  });

  group('au lancement', () {
    test('plusieurs utilisateurs : on demande qui regarde avant d’ouvrir',
        () async {
      final api = await sharedTelevision();

      final auth = AuthProvider(api, startupRetryPauses: const []);
      await _settle(auth);

      expect(auth.needsUserChoice, isTrue);
      expect(auth.isAuthenticated, isFalse);
      expect(api.meCalls, isEmpty,
          reason: 'aucune session ne s’ouvre avant le choix');
    });

    test('le choix ouvre la session de la personne choisie', () async {
      final api = await sharedTelevision();
      final auth = AuthProvider(api, startupRetryPauses: const []);
      await _settle(auth);
      var resets = 0;
      auth.onServerChanged = () => resets++;
      final mathis = auth.usersOnActiveServer.first;

      await auth.chooseUser(mathis.id);

      expect(auth.needsUserChoice, isFalse);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.currentUser?.username, 'mathis');
      expect(api.meCalls, ['mathis']);
      expect(resets, 1, reason: 'rien de Léa ne doit rester en mémoire');
    });

    test('un seul utilisateur par serveur : rien à demander', () async {
      final api = _FakeApiClient();
      await api.initialize();
      await api.rememberSession(
        serverUrl: 'http://maison.local',
        username: 'mathis',
        token: 'jeton-maison',
      );
      await api.rememberSession(
        serverUrl: 'http://paul.local',
        username: 'mathis',
        token: 'jeton-paul',
      );

      final auth = AuthProvider(api, startupRetryPauses: const []);
      await _settle(auth);

      expect(auth.needsUserChoice, isFalse);
      expect(auth.isAuthenticated, isTrue);
    });
  });

  testWidgets('« Qui regarde ? » liste les personnes et ouvre la choisie',
      (tester) async {
    final api = await tester.runAsync(sharedTelevision);
    final auth = AuthProvider(api!, startupRetryPauses: const []);
    await tester.runAsync(() => _settle(auth));

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: const MaterialApp(home: UserChoiceScreen(atStartup: true)),
      ),
    );

    expect(find.text('Qui regarde ?'), findsOneWidget);
    expect(find.text('mathis'), findsOneWidget);
    expect(find.text('lea'), findsOneWidget);
    expect(find.bySemanticsLabel('Ajouter un utilisateur'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Regarder en tant que mathis'));
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && !auth.isAuthenticated; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });

    expect(auth.currentUser?.username, 'mathis');
  });

  /// Monte l'écran comme le fait l'app au lancement, télévision ou non.
  Future<AuthProvider> mountPicker(WidgetTester tester, {bool isTv = false}) async {
    // L'autofocus de TvFocusable lit le mode global, pas seulement la portée.
    TvMode.enabled.value = isTv;
    addTearDown(() => TvMode.enabled.value = false);
    final api = await tester.runAsync(sharedTelevision);
    final auth = AuthProvider(api!, startupRetryPauses: const []);
    await tester.runAsync(() => _settle(auth));
    await tester.pumpWidget(TvScope(
      isTv: isTv,
      child: ChangeNotifierProvider<AuthProvider>.value(
        value: auth,
        child: MaterialApp(
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            ...tvSelectShortcuts,
          },
          home: const UserChoiceScreen(atStartup: true),
        ),
      ),
    ));
    await tester.pump();
    return auth;
  }

  testWidgets('« Qui regarde ? » nomme chaque pastille', (tester) async {
    final handle = tester.ensureSemantics();
    await mountPicker(tester);

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('à la télécommande : focus sur la première personne, OK choisit',
      (tester) async {
    final auth = await mountPicker(tester, isTv: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && !auth.isAuthenticated; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });

    expect(auth.currentUser?.username, 'lea',
        reason: 'le focus part de mathis, un pas à droite mène à Léa');
  });

  test('ajouter quelqu’un sur un serveur déjà connu rend son compte',
      () async {
    final api = await sharedTelevision();
    final auth = AuthProvider(api, startupRetryPauses: const []);
    await _settle(auth);
    await auth.chooseUser(api.servers.active!.id);
    final added = await auth.addServerWithPassword(
      serverUrl: 'http://maison.local',
      username: 'zoe',
      password: 'secret',
    );

    expect(added.username, 'zoe',
        reason: 'pas le premier compte de cette adresse');
    expect(auth.currentUser?.username, 'lea',
        reason: 'l’ajout ne bascule pas sous les doigts de l’utilisateur');
    expect(auth.usersOnActiveServer.length, 3);
  });
}
