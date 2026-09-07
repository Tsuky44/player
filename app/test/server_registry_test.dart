import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/server_registry.dart';
import 'package:onyx/services/api_client.dart';

/// Le carnet de serveurs : ce qui permet à un même appareil de tenir plusieurs
/// comptes et d'en changer sans en perdre un. Voir ADR-0013.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mockStorage(Map<String, Object> initial) {
    SharedPreferences.setMockInitialValues(initial);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  }

  setUp(() => mockStorage({}));

  group('normalisation', () {
    test('deux écritures de la même adresse donnent le même compte', () {
      const written = [
        '192.168.1.50:8080',
        'http://192.168.1.50:8080',
        'http://192.168.1.50:8080/',
        '  http://192.168.1.50:8080  ',
      ];
      final ids =
          written.map((url) => ServerAccount.idFor(url, 'mathis')).toSet();
      expect(ids, hasLength(1),
          reason: 'sinon « ajouter un serveur » en crée un par frappe près');
    });

    test('deux serveurs voisins ne se confondent pas', () {
      expect(
        ServerAccount.idFor('http://192.168.1.50:8080', 'mathis'),
        isNot(ServerAccount.idFor('http://192.168.1.51:8080', 'mathis')),
      );
      expect(
        ServerAccount.idFor('http://maison.local', 'mathis'),
        isNot(ServerAccount.idFor('http://maison.local', 'julie')),
      );
    });
  });

  test('deux serveurs cohabitent, chacun avec son jeton', () async {
    final registry = ServerRegistry();
    await registry.load();

    final maison = await registry.remember(
      url: 'http://maison.local:8080',
      username: 'mathis',
      token: 'jeton-maison',
    );
    final chezPaul = await registry.remember(
      url: 'http://paul.local:8080',
      username: 'mathis',
      token: 'jeton-paul',
    );

    expect(registry.accounts, hasLength(2));
    expect(registry.active?.id, chezPaul.id);
    expect(await registry.tokenFor(maison.id), 'jeton-maison');
    expect(await registry.tokenFor(chezPaul.id), 'jeton-paul');

    // Revenir sur le premier ne renégocie rien : son jeton n'avait pas disparu,
    // il n'avait simplement pas cours.
    expect(await registry.activate(maison.id), isTrue);
    expect(registry.active?.id, maison.id);
    expect(await registry.tokenFor(maison.id), 'jeton-maison');
  });

  test('se reconnecter au même serveur remplace le jeton sans doubler la ligne',
      () async {
    final registry = ServerRegistry();
    await registry.load();

    await registry.remember(
      url: 'http://maison.local:8080',
      username: 'mathis',
      token: 'ancien',
    );
    final again = await registry.remember(
      url: 'maison.local:8080/',
      username: 'mathis',
      token: 'nouveau',
    );

    expect(registry.accounts, hasLength(1));
    expect(await registry.tokenFor(again.id), 'nouveau');
  });

  test('retirer le serveur actif fait passer au suivant', () async {
    final registry = ServerRegistry();
    await registry.load();

    final maison = await registry.remember(
      url: 'http://maison.local',
      username: 'mathis',
      token: 'a',
    );
    final paul = await registry.remember(
      url: 'http://paul.local',
      username: 'mathis',
      token: 'b',
    );

    expect(registry.active?.id, paul.id);
    await registry.forget(paul.id);

    expect(registry.active?.id, maison.id,
        reason:
            'se déconnecter d’un serveur n’est pas se déconnecter de l’app');
    expect(await registry.tokenFor(paul.id), isNull,
        reason: 'un compte retiré ne laisse pas son jeton derrière lui');
  });

  test('changer l’adresse d’un serveur garde sa session', () async {
    final registry = ServerRegistry();
    await registry.load();

    final before = await registry.remember(
      url: 'http://192.168.1.50:8080',
      username: 'mathis',
      token: 'jeton',
    );
    await registry.writeProfile(before.id, '{"username":"mathis"}');

    final after =
        await registry.updateUrl(before.id, 'https://onyx.exemple.fr');

    expect(registry.accounts, hasLength(1));
    expect(after!.url, 'https://onyx.exemple.fr');
    expect(await registry.tokenFor(after.id), 'jeton',
        reason: 'le jeton appartient au serveur, pas à l’adresse');
    expect(await registry.readProfile(after.id), '{"username":"mathis"}');
  });

  test('une session mono-serveur est reprise à la mise à jour', () async {
    mockStorage({
      'server_url': 'http://maison.local:8080',
      'auth_token': 'jeton-hérité',
      'last_username': 'mathis',
      'cached_profile': '{"username":"mathis"}',
    });

    final registry = ServerRegistry();
    await registry.load();

    expect(registry.accounts, hasLength(1),
        reason: 'sinon la mise à jour déconnecterait tout le monde');
    final account = registry.active!;
    expect(account.url, 'http://maison.local:8080');
    expect(account.username, 'mathis');
    expect(await registry.tokenFor(account.id), 'jeton-hérité');
    expect(await registry.readProfile(account.id), '{"username":"mathis"}');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth_token'), isNull,
        reason:
            'un jeton que plus personne ne lit est un identifiant qui traîne');
  });

  test('le carnet survit à un redémarrage', () async {
    final first = ServerRegistry();
    await first.load();
    final maison = await first.remember(
      url: 'http://maison.local',
      username: 'mathis',
      token: 'a',
    );
    await first.remember(
      url: 'http://paul.local',
      username: 'mathis',
      token: 'b',
    );
    await first.activate(maison.id);

    final second = ServerRegistry();
    await second.load();

    expect(second.accounts.map((a) => a.url),
        containsAll(<String>['http://maison.local', 'http://paul.local']));
    expect(second.active?.id, maison.id);
  });

  test(
      'une demande en attente survit au redémarrage puis disparaît une fois '
      'satisfaite', () async {
    final registry = ServerRegistry();
    await registry.load();

    await registry.addPendingRequest(PendingAccessRequest(
      url: 'http://paul.local',
      username: 'mathis',
      requestCode: 'code-privé',
      createdAt: DateTime.now(),
    ));

    final reopened = ServerRegistry();
    await reopened.load();
    expect(reopened.pendingRequests, hasLength(1));
    expect(reopened.pendingRequests.first.requestCode, 'code-privé');

    // L'approbation entre le compte au carnet : la demande n'a plus lieu d'être.
    await reopened.remember(
      url: 'http://paul.local',
      username: 'mathis',
      token: 'jeton',
    );
    expect(reopened.pendingRequests, isEmpty);
  });

  test('une approbation n’arrache pas l’écran quand une session est ouverte',
      () async {
    final registry = ServerRegistry();
    await registry.load();

    final maison = await registry.remember(
      url: 'http://maison.local',
      username: 'mathis',
      token: 'a',
    );
    await registry.remember(
      url: 'http://paul.local',
      username: 'mathis',
      token: 'b',
      activate: false,
    );

    expect(registry.accounts, hasLength(2));
    expect(registry.active?.id, maison.id);
  });

  test('un carnet illisible ne bloque pas le démarrage', () async {
    mockStorage({'onyx_servers_v1': 'ceci n’est pas du JSON'});

    final registry = ServerRegistry();
    await registry.load();

    expect(registry.accounts, isEmpty);
    expect(registry.active, isNull);
  });

  test('le carnet écrit ce qu’il relit', () async {
    final registry = ServerRegistry();
    await registry.load();
    await registry.remember(
      url: 'http://maison.local',
      username: 'mathis',
      token: 'a',
      label: 'À la maison',
    );

    final prefs = await SharedPreferences.getInstance();
    final raw =
        jsonDecode(prefs.getString('onyx_servers_v1')!) as Map<String, dynamic>;
    expect(raw['accounts'], hasLength(1));
    expect((raw['accounts'] as List).first['label'], 'À la maison');
    expect(raw['active'], isNotNull);
    // Le jeton n'a rien à faire dans le carnet lui-même.
    expect(prefs.getString('onyx_servers_v1'), isNot(contains('"a"')));
  });
  test('explicit links persist, merge and survive an address change', () async {
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.local', username: 'alice', token: 'a');
    final b = await registry.remember(
        url: 'http://b.local', username: 'bob', token: 'b');
    final c = await registry.remember(
        url: 'http://c.local', username: 'charlie', token: 'c');
    expect(registry.linkedAccounts(a.id).map((a) => a.id), [a.id]);
    await registry.linkAccounts(a.id, b.id);
    await registry.linkAccounts(b.id, c.id);
    final restored = ServerRegistry();
    await restored.load();
    expect(restored.linkedAccounts(c.id), hasLength(3));
    final moved = await restored.updateUrl(a.id, 'http://a-new.local');
    expect(restored.linkedAccounts(b.id).map((a) => a.id), contains(moved!.id));
    expect(
        restored.linkedAccounts(b.id).map((a) => a.id), isNot(contains(a.id)));
    await restored.unlinkAccount(b.id);
    expect(restored.linkedAccounts(b.id), hasLength(1));
    expect(restored.linkedAccounts(c.id), hasLength(2));
    await restored.forget(moved.id);
    final last = ServerRegistry();
    await last.load();
    expect(last.linkedAccounts(c.id), hasLength(1));
  });
  test('a player API stays pinned when the active account changes', () async {
    final registry = ServerRegistry();
    await registry.load();
    final a = await registry.remember(
        url: 'http://a.local', username: 'alice', token: 'a');
    final b = await registry.remember(
        url: 'http://b.local', username: 'bob', token: 'b');
    final api = ApiClient(registry: registry);
    final player = await api.pinToAccount(a.id);
    await registry.activate(b.id);
    expect(player.accountId, a.id);
    expect(player.getStreamUrl(7), 'http://a.local/stream?media_id=7');
    expect(player.hasSavedToken, isTrue);
  });
}
