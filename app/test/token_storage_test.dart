import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/services/server_registry.dart';

/// Où vit le jeton de session : le coffre du système, et les préférences
/// (un fichier en clair) seulement quand le coffre ne garde rien. Voir
/// ADR-0079.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  void secureStore(Map<String, String>? vault) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (vault == null) throw PlatformException(code: 'unavailable');
      final args = (call.arguments as Map).cast<String, Object?>();
      final key = args['key'] as String?;
      switch (call.method) {
        case 'write':
          vault[key!] = args['value'] as String;
          return null;
        case 'read':
          return vault[key];
        case 'delete':
          vault.remove(key);
          return null;
      }
      return null;
    });
  }

  test('le jeton va au coffre, pas dans les préférences', () async {
    SharedPreferences.setMockInitialValues({});
    final vault = <String, String>{};
    secureStore(vault);

    final registry = ServerRegistry();
    await registry.load();
    final account = await registry.remember(
        url: 'http://maison.local:8080', username: 'mathis', token: 'jeton');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('auth_token')), isEmpty);
    expect(vault.values, contains('jeton'));
    expect(await registry.tokenFor(account.id), 'jeton');
  });

  test('un jeton resté dans les préférences rejoint le coffre', () async {
    final vault = <String, String>{};
    secureStore(vault);
    SharedPreferences.setMockInitialValues({});
    final registry = ServerRegistry();
    await registry.load();
    final account = await registry.remember(
        url: 'http://maison.local:8080', username: 'mathis', token: 'jeton');
    vault.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token_${account.id}', 'ancien');

    expect(await registry.tokenFor(account.id), 'ancien');
    expect(prefs.getString('auth_token_${account.id}'), isNull);
    expect(vault.values, contains('ancien'));
  });

  test('sans coffre, la session tient par les préférences', () async {
    SharedPreferences.setMockInitialValues({});
    secureStore(null);

    final registry = ServerRegistry();
    await registry.load();
    final account = await registry.remember(
        url: 'http://maison.local:8080', username: 'mathis', token: 'jeton');

    expect(await registry.tokenFor(account.id), 'jeton');
  });
}
