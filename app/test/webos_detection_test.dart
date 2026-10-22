import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/webos_user_agent.dart';

/// Un téléviseur LG n'est reconnu qu'à son agent utilisateur, et sa
/// télécommande qu'à ses `keyCode` (ADR-0076). Manquer l'un, c'est un
/// téléviseur traité comme un onglet : transcodé, sans focus, sans Retour.
void main() {
  group('agent utilisateur', () {
    test('les téléviseurs LG sont reconnus', () {
      // webOS 6 (2021) et webOS 23.
      expect(
        isWebOSUserAgent('Mozilla/5.0 (Web0S; Linux/SmartTV) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.79 '
            'Safari/537.36 WebAppManager'),
        isTrue,
      );
      expect(
        isWebOSUserAgent('Mozilla/5.0 (Web0S; Linux/SmartTV) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.128 '
            'Safari/537.36 WebAppManager'),
        isTrue,
      );
    });

    test('un navigateur de bureau ne l\'est pas', () {
      expect(
        isWebOSUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 '
            'Safari/537.36'),
        isFalse,
      );
      expect(
        isWebOSUserAgent('Mozilla/5.0 (Linux; Android 14; BRAVIA 4K) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'),
        isFalse,
      );
    });
  });

  // Flutter écoute les touches sur la fenêtre, en capture : seul un écouteur
  // posé avant lui peut lui cacher l'événement d'origine. Chargé après, le
  // script laisserait passer chaque touche LG deux fois (ADR-0076).
  test('la réécriture des touches LG se charge avant Flutter', () {
    final html = File('web/index.html').readAsStringSync();
    final remote = html.indexOf('<script src="webos_remote.js"></script>');
    final flutter = html.indexOf('src="flutter_bootstrap.js"');
    expect(remote, isNonNegative,
        reason: 'webos_remote.js doit être chargé, sans async ni defer');
    expect(remote, lessThan(flutter));
  });
}
