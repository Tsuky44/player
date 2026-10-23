import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/server_account.dart';
import 'package:onyx/services/server_registry.dart';
import 'package:onyx/services/server_scheme.dart';

/// HTTPS dès que le serveur le parle, HTTP seulement sinon. Voir ADR-0080.
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

  ServerScheme speaking(Set<String> httpsHosts) => ServerScheme(
      probe: (base) async => httpsHosts.contains(Uri.parse(base).authority));

  group('resolve', () {
    test('une adresse sans préfixe passe en HTTPS quand le serveur y répond',
        () async {
      final scheme = speaking({'onyx.example', 'maison.local:8080'});
      expect(await scheme.resolve('onyx.example'), 'https://onyx.example');
      expect(await scheme.resolve('http://maison.local:8080/'),
          'https://maison.local:8080');
    });

    test('un serveur qui ne parle que HTTP reste en HTTP', () async {
      final scheme = speaking({});
      expect(await scheme.resolve('192.168.1.10:8080'),
          'http://192.168.1.10:8080');
    });

    // Un intermédiaire qui bloque HTTPS ne doit pas faire repasser l'app en
    // clair.
    test('une adresse en HTTPS n’est jamais rabattue sur HTTP', () async {
      var probed = false;
      final scheme = ServerScheme(probe: (_) async => probed = true);
      expect(await scheme.resolve('https://onyx.example'),
          'https://onyx.example');
      expect(probed, isFalse);
    });
  });

  test('un compte enregistré en HTTP suit son serveur passé en HTTPS',
      () async {
    final registry = ServerRegistry();
    await registry.load();
    final maison = await registry.remember(
        url: 'http://maison.local:8080', username: 'mathis', token: 'jeton');
    final ami = await registry.remember(
        url: 'http://ami.local:8080', username: 'mathis', token: 'autre');
    await registry.activate(maison.id);

    final changed =
        await speaking({'maison.local:8080'}).upgradeAccounts(registry);

    expect(changed, isTrue);
    expect(registry.active?.url, 'https://maison.local:8080');
    expect(await registry.tokenFor(registry.active!.id), 'jeton');
    expect(registry.accountById(ami.id)?.url, 'http://ami.local:8080');
  });

  test('passer un autre compte en HTTPS ne change pas le compte actif',
      () async {
    final registry = ServerRegistry();
    await registry.load();
    final ami = await registry.remember(
        url: 'http://ami.local:8080', username: 'mathis', token: 'autre');
    final maison = await registry.remember(
        url: 'http://maison.local:8080', username: 'mathis', token: 'jeton');
    await registry.activate(maison.id);

    final changed = await speaking({'ami.local:8080'}).upgradeAccounts(registry);

    expect(changed, isFalse);
    expect(registry.active?.id, maison.id);
    expect(
        registry.accounts.map((a) => a.url), contains('https://ami.local:8080'));
    expect(registry.accountById(ami.id), isNull);
  });

  test('le même serveur, en HTTP ou en HTTPS', () {
    expect(ServerAccount.sameAddress('http://a.local:8080', 'https://a.local:8080'),
        isTrue);
    expect(ServerAccount.sameAddress('https://a.local:8080', 'https://a.local:8081'),
        isFalse);
  });
}
