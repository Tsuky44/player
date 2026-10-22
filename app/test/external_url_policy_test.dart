import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/app_download.dart';
import 'package:onyx/utils/external_url_policy.dart';

void main() {
  group('isOpenableExternalUrl', () {
    test('ouvre un lien web absolu', () {
      expect(isOpenableExternalUrl('https://www.youtube.com/watch?v=abc_-1'),
          isTrue);
      expect(
          isOpenableExternalUrl(
              'http://192.168.1.10:8080/api/downloads/Onyx-1.0.0-macos.dmg'),
          isTrue);
    });

    // Un serveur malveillant ne doit pouvoir ni exécuter de script dans l'app
    // web, ni glisser une commande au shell qui ouvre le lien.
    test('refuse ce qui n’est pas un lien web', () {
      for (final url in [
        'javascript:alert(1)',
        'file:///C:/Windows/System32/calc.exe',
        '\\\\attaquant\\partage\\a.exe',
        '/api/downloads/x',
        'https://h/x" & calc',
        'https://h/a b',
        'https://h/a\nb',
        '',
      ]) {
        expect(isOpenableExternalUrl(url), isFalse, reason: url);
      }
    });
  });

  group('AppDownload', () {
    AppDownload download({String file = 'Onyx-1.0.0-macos.dmg', String url = '/api/downloads/Onyx-1.0.0-macos.dmg'}) =>
        AppDownload(
            platform: 'macos',
            label: 'macOS',
            file: file,
            url: url,
            version: '1.0.0',
            size: 1);

    test('un nom de fichier ne sort jamais du dossier de téléchargement', () {
      expect(download(file: '../../.zshrc').localFileName, '.zshrc');
      expect(download(file: '..\\..\\x.exe').localFileName, 'x.exe');
      expect(download(file: '..').localFileName, 'onyx-update');
      expect(download().localFileName, 'Onyx-1.0.0-macos.dmg');
    });

    test('le chemin reste un fichier de /api/downloads', () {
      expect(download().safePath, '/api/downloads/Onyx-1.0.0-macos.dmg');
      expect(download(url: '@evil.example/x.dmg').safePath,
          '/api/downloads/Onyx-1.0.0-macos.dmg');
      expect(download(url: '/api/downloads/x&calc').safePath,
          '/api/downloads/Onyx-1.0.0-macos.dmg');
    });
  });
}
