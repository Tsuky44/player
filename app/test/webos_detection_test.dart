import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/webos_remote_keys.dart';
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

  group('télécommande', () {
    test('Retour devient Échap, que l\'habillage TV traite comme un retour',
        () {
      expect(webOSRemoteKeyName(keyCode: 461, key: 'Unidentified'), 'Escape');
    });

    test('les touches de lecture prennent leur nom média', () {
      expect(
          webOSRemoteKeyName(keyCode: 415, key: 'Unidentified'), 'MediaPlay');
      // 19 est nommé comme la touche Pause d'un clavier de PC.
      expect(webOSRemoteKeyName(keyCode: 19, key: 'Pause'), 'MediaPause');
      expect(webOSRemoteKeyName(keyCode: 417, key: 'Unidentified'),
          'MediaFastForward');
      expect(
          webOSRemoteKeyName(keyCode: 412, key: 'Unidentified'), 'MediaRewind');
    });

    test('une touche déjà bien nommée ou ordinaire passe telle quelle', () {
      expect(webOSRemoteKeyName(keyCode: 415, key: 'MediaPlay'), isNull);
      expect(webOSRemoteKeyName(keyCode: 13, key: 'Enter'), isNull);
      expect(webOSRemoteKeyName(keyCode: 38, key: 'ArrowUp'), isNull);
    });
  });
}
