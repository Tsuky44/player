import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/models/server_account.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/services/api_client.dart';

/// Un serveur qui répond ce qu'on lui dit de répondre, sans réseau.
class _FakeApiClient extends ApiClient {
  /// Le profil que rend `/api/auth/me`, par adresse de serveur.
  final Map<String, User> profiles = {};

  /// Les verdicts servis par `/api/auth/access/poll`, par code de demande.
  final Map<String, AccessRequestVerdict> verdicts = {};

  final List<String> meCalls = [];
  bool logoutCalled = false;

  @override
  Future<User> getMe() async {
    meCalls.add(baseUrl);
    final user = profiles[baseUrl];
    if (user == null) throw Exception('aucun profil pour $baseUrl');
    return user;
  }

  @override
  Future<void> logout() async {
    logoutCalled = true;
    await clearAuth();
  }

  @override
  Future<AccessRequestTicket> requestAccess({
    required String serverUrl,
    required String username,
    required String password,
    String? deviceName,
    String? message,
  }) async {
    return AccessRequestTicket(
      requestCode: 'code-$username',
      username: username,
      expiresIn: const Duration(days: 7),
      pollInterval: const Duration(seconds: 5),
    );
  }

  @override
  Future<AccessRequestVerdict> pollAccessRequest({
    required String serverUrl,
    required String requestCode,
  }) async {
    return verdicts[requestCode] ??
        const AccessRequestVerdict(status: AccessRequestStatus.pending);
  }
}

User _user(String username, {int id = 1}) => User(
      id: id,
      username: username,
      permissions: const Permissions(requestMedia: true),
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

  /// Un appareil déjà connecté à « maison », prêt à en ajouter un second.
  Future<(_FakeApiClient, AuthProvider)> signedInAtHome() async {
    final api = _FakeApiClient();
    await api.initialize();
    api.profiles['http://maison.local'] = _user('mathis');
    await api.rememberSession(
      serverUrl: 'http://maison.local',
      username: 'mathis',
      token: 'jeton-maison',
    );
    final auth = AuthProvider(api);
    // tryAutoLogin part depuis le constructeur ; on attend qu'il retombe.
    await Future<void>.delayed(Duration.zero);
    return (api, auth);
  }

  test('une demande d’accès est notée sur l’appareil, pas seulement à l’écran',
      () async {
    final (api, auth) = await signedInAtHome();

    final pending = await auth.requestAccess(
      serverUrl: 'paul.local',
      username: 'mathis',
      password: 'secret',
      message: 'salut',
    );

    expect(pending.url, 'http://paul.local',
        reason: 'l’adresse est normalisée avant d’être retenue');
    expect(auth.pendingAccessRequests, hasLength(1));
    // Elle survit au redémarrage de l'app : la réponse peut prendre des jours.
    final reopened = ApiClient();
    await reopened.initialize();
    expect(reopened.servers.pendingRequests, hasLength(1));
    expect(reopened.servers.pendingRequests.first.requestCode, 'code-mathis');
    expect(api.servers.accounts, hasLength(1),
        reason: 'une demande en attente n’est pas encore un compte');
  });

  test('une approbation entre au carnet sans arracher la session en cours',
      () async {
    final (api, auth) = await signedInAtHome();
    await auth.requestAccess(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      password: 'secret',
    );
    api.verdicts['code-mathis'] = AccessRequestVerdict(
      status: AccessRequestStatus.approved,
      token: 'jeton-paul',
      user: _user('mathis', id: 7).toJson(),
    );

    await auth.refreshAccessRequests();

    expect(auth.servers, hasLength(2));
    expect(auth.activeServer?.url, 'http://maison.local',
        reason: 'l’utilisateur regardait peut-être un film');
    expect(auth.pendingAccessRequests, isEmpty);
    // Le jeton du nouveau serveur est bien là, prêt pour la bascule.
    final paul = api.servers.accountForUrl('http://paul.local')!;
    expect(await api.servers.tokenFor(paul.id), 'jeton-paul');
  });

  test('sur un appareil sans compte, l’approbation ouvre la session', () async {
    final api = _FakeApiClient();
    await api.initialize();
    final auth = AuthProvider(api);
    await Future<void>.delayed(Duration.zero);

    await auth.requestAccess(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      password: 'secret',
    );
    api.verdicts['code-mathis'] = AccessRequestVerdict(
      status: AccessRequestStatus.approved,
      token: 'jeton-paul',
      user: _user('mathis', id: 7).toJson(),
    );

    await auth.refreshAccessRequests();

    expect(auth.isAuthenticated, isTrue,
        reason: 'c’est précisément ce que l’appareil attendait');
    expect(auth.currentUser?.username, 'mathis');
    expect(auth.activeServer?.url, 'http://paul.local');
  });

  test('un refus est dit une fois, puis la demande disparaît', () async {
    final (api, auth) = await signedInAtHome();
    await auth.requestAccess(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      password: 'secret',
    );
    api.verdicts['code-mathis'] =
        const AccessRequestVerdict(status: AccessRequestStatus.denied);

    await auth.refreshAccessRequests();

    expect(auth.pendingAccessRequests, isEmpty);
    expect(auth.servers, hasLength(1),
        reason: 'un refus ne crée rien');
  });

  test('basculer relit l’identité du serveur d’arrivée', () async {
    final (api, auth) = await signedInAtHome();
    api.profiles['http://paul.local'] = _user('mathis', id: 7);
    await api.rememberSession(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      token: 'jeton-paul',
      activate: false,
    );
    final paul = api.servers.accountForUrl('http://paul.local')!;

    api.meCalls.clear();
    final ok = await auth.switchServer(paul.id);

    expect(ok, isTrue);
    expect(api.meCalls, ['http://paul.local'],
        reason: 'les droits ne sont pas les mêmes des deux côtés');
    expect(auth.activeServer?.id, paul.id);
    expect(auth.currentUser?.id, 7);
  });

  test('la bascule prévient qui doit vider ce qui appartenait à l’autre serveur',
      () async {
    final (api, auth) = await signedInAtHome();
    api.profiles['http://paul.local'] = _user('mathis', id: 7);
    await api.rememberSession(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      token: 'jeton-paul',
      activate: false,
    );

    var cleared = 0;
    auth.onServerChanged = () => cleared++;
    await auth.switchServer(api.servers.accountForUrl('http://paul.local')!.id);

    expect(cleared, 1,
        reason: 'les identifiants de médias sont propres à un serveur');
  });

  test('se déconnecter d’un serveur n’est pas se déconnecter de l’app',
      () async {
    final (api, auth) = await signedInAtHome();
    api.profiles['http://paul.local'] = _user('mathis', id: 7);
    await api.rememberSession(
      serverUrl: 'http://paul.local',
      username: 'mathis',
      token: 'jeton-paul',
    );
    // On est maintenant sur « paul » ; s'en déconnecter doit ramener à « maison ».
    expect(api.servers.active?.url, 'http://paul.local');

    await auth.logout();

    expect(api.logoutCalled, isTrue);
    expect(auth.isAuthenticated, isTrue);
    expect(auth.activeServer?.url, 'http://maison.local');
    expect(auth.servers, hasLength(1));
  });

  test('le dernier serveur retiré ramène bien à l’écran de connexion',
      () async {
    final (_, auth) = await signedInAtHome();

    await auth.logout();

    expect(auth.isAuthenticated, isFalse);
    expect(auth.servers, isEmpty);
  });
}
