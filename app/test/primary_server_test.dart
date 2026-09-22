import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/services/api_client.dart';

/// Le serveur principal : celui sur lequel l'app se remet à chaque lancement,
/// et ce qu'elle fait quand il ne répond pas. Voir ADR-0013 pour le carnet.

/// Un serveur qui répond, ou pas, selon ce qu'on lui dit.
class _FakeApiClient extends ApiClient {
  /// Le profil rendu par `/api/auth/me`, par adresse de serveur.
  final Map<String, User> profiles = {};

  /// Les adresses qui ne répondent pas du tout — le serveur éteint, le NAS
  /// resté à la maison.
  final Set<String> down = {};

  final List<String> meCalls = [];

  @override
  Future<User> getMe() async {
    meCalls.add(baseUrl);
    if (down.contains(baseUrl)) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/api/auth/me'),
        reason: 'serveur injoignable',
      );
    }
    final user = profiles[baseUrl];
    if (user == null) {
      final options = RequestOptions(path: '/api/auth/me');
      throw DioException.badResponse(
        statusCode: 401,
        requestOptions: options,
        response: Response<dynamic>(statusCode: 401, requestOptions: options),
      );
    }
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

  /// Un appareil connecté à « maison » puis à « paul », actif sur paul.
  Future<_FakeApiClient> deviceWithTwoServers() async {
    final api = _FakeApiClient();
    await api.initialize();
    api.profiles['http://maison.local'] = _user('mathis');
    api.profiles['http://paul.local'] = _user('mathis', id: 7);
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
    return api;
  }

  group('carnet', () {
    test('le serveur principal survit au redémarrage de l’app', () async {
      final api = await deviceWithTwoServers();
      final maison = api.servers.accountForUrl('http://maison.local')!;
      await api.servers.setPrimary(maison.id);

      final reopened = ApiClient();
      await reopened.initialize();

      expect(reopened.servers.primary?.url, 'http://maison.local');
    });

    test('retirer le serveur principal le libère', () async {
      final api = await deviceWithTwoServers();
      final maison = api.servers.accountForUrl('http://maison.local')!;
      await api.servers.setPrimary(maison.id);

      await api.forgetAccount(maison.id);

      expect(api.servers.primary, isNull,
          reason: 'sinon le démarrage viserait un compte sans jeton');
    });

    test('changer l’adresse du serveur principal ne le dépose pas', () async {
      final api = await deviceWithTwoServers();
      final maison = api.servers.accountForUrl('http://maison.local')!;
      await api.servers.setPrimary(maison.id);

      await api.activateAccount(maison.id);
      await api.updateActiveServerUrl('http://maison.duckdns.org');

      expect(api.servers.primary?.url, 'http://maison.duckdns.org');
    });
  });

  test('l’app démarre sur le principal, pas sur le dernier regardé', () async {
    final api = await deviceWithTwoServers();
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await api.servers.setPrimary(maison.id);
    expect(api.servers.active?.url, 'http://paul.local',
        reason: 'c’est bien l’autre serveur qu’on quittait');

    final auth = AuthProvider(api);
    await _settle(auth);

    expect(auth.activeServer?.url, 'http://maison.local');
    expect(auth.isAuthenticated, isTrue);
    expect(auth.needsServerChoice, isFalse);
  });

  test('sans serveur principal, l’app reprend où elle en était', () async {
    final api = await deviceWithTwoServers();

    final auth = AuthProvider(api);
    await _settle(auth);

    expect(auth.activeServer?.url, 'http://paul.local');
    expect(auth.needsServerChoice, isFalse);
  });

  test('principal muet : l’app propose les autres au lieu du hors ligne',
      () async {
    final api = await deviceWithTwoServers();
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await api.servers.setPrimary(maison.id);
    await api.activateAccount(maison.id);
    // Un profil est bien en cache : le hors ligne serait possible, il n’est
    // simplement pas ce qu’on a demandé.
    await api.cacheProfile(_user('mathis'));
    api.down.add('http://maison.local');

    final auth = AuthProvider(api);
    await _settle(auth);

    expect(auth.needsServerChoice, isTrue);
    expect(auth.unreachablePrimary?.url, 'http://maison.local');
    expect(auth.isAuthenticated, isFalse);
    expect(auth.isOfflineSession, isFalse);
  });

  test('un seul serveur : rien à proposer, la session hors ligne reprend',
      () async {
    final api = _FakeApiClient();
    await api.initialize();
    api.profiles['http://maison.local'] = _user('mathis');
    await api.rememberSession(
      serverUrl: 'http://maison.local',
      username: 'mathis',
      token: 'jeton-maison',
    );
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await api.servers.setPrimary(maison.id);
    await api.cacheProfile(_user('mathis'));
    api.down.add('http://maison.local');

    final auth = AuthProvider(api);
    await _settle(auth);

    expect(auth.needsServerChoice, isFalse,
        reason: 'une liste d’un seul serveur ne propose rien');
    expect(auth.isOfflineSession, isTrue);
  });

  test('basculer répond à la question et ouvre l’autre serveur', () async {
    final api = await deviceWithTwoServers();
    final maison = api.servers.accountForUrl('http://maison.local')!;
    final paul = api.servers.accountForUrl('http://paul.local')!;
    await api.servers.setPrimary(maison.id);
    api.down.add('http://maison.local');

    final auth = AuthProvider(api);
    await _settle(auth);
    expect(auth.needsServerChoice, isTrue);

    final ok = await auth.switchServer(paul.id);

    expect(ok, isTrue);
    expect(auth.needsServerChoice, isFalse);
    expect(auth.activeServer?.url, 'http://paul.local');
    expect(auth.isAuthenticated, isTrue);
    expect(api.servers.primary?.url, 'http://maison.local',
        reason: 'une bascule d’un soir ne déplace pas le serveur de démarrage');
  });

  test('le principal revenu se rattrape sans relancer l’app', () async {
    final api = await deviceWithTwoServers();
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await api.servers.setPrimary(maison.id);
    api.down.add('http://maison.local');

    final auth = AuthProvider(api);
    await _settle(auth);
    expect(auth.needsServerChoice, isTrue);

    api.down.clear();
    final ok = await auth.retryPrimaryServer();

    expect(ok, isTrue);
    expect(auth.needsServerChoice, isFalse);
    expect(auth.activeServer?.url, 'http://maison.local');
    expect(auth.isAuthenticated, isTrue);
  });

  test('on peut rester hors ligne sur le principal', () async {
    final api = await deviceWithTwoServers();
    final maison = api.servers.accountForUrl('http://maison.local')!;
    await api.servers.setPrimary(maison.id);
    await api.activateAccount(maison.id);
    await api.cacheProfile(_user('mathis'));
    api.down.add('http://maison.local');

    final auth = AuthProvider(api);
    await _settle(auth);

    final opened = await auth.continueOfflineOnPrimary();

    expect(opened, isTrue);
    expect(auth.needsServerChoice, isFalse);
    expect(auth.isOfflineSession, isTrue);
    expect(auth.activeServer?.url, 'http://maison.local');
  });
}
