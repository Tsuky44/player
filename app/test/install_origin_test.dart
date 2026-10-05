import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/install_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// L'adresse du serveur déduite de l'origine de l'installeur — ADR-0042.
void main() {
  String marker(String hostUrl) => '[ZoneTransfer]\r\n'
      'ZoneId=3\r\n'
      'ReferrerUrl=https://onyx.example.com/\r\n'
      'HostUrl=$hostUrl\r\n';

  group('InstallOrigin.serverUrlFromMarker', () {
    test('un installeur pris sur le serveur donne la racine du serveur', () {
      expect(
        InstallOrigin.serverUrlFromMarker(marker(
            'https://onyx.example.com/api/downloads/Onyx-1.2.0-windows.exe')),
        'https://onyx.example.com',
      );
    });

    test('le port et le sous-chemin du reverse proxy sont conservés', () {
      expect(
        InstallOrigin.serverUrlFromMarker(marker(
            'http://192.168.1.50:8080/api/downloads/Onyx-1.2.0-windows.exe')),
        'http://192.168.1.50:8080',
      );
      expect(
        InstallOrigin.serverUrlFromMarker(marker(
            'https://example.com/onyx/api/downloads/Onyx-1.2.0-windows.exe')),
        'https://example.com/onyx',
      );
    });

    test('un installeur venu d\'ailleurs ne désigne aucun serveur', () {
      expect(
        InstallOrigin.serverUrlFromMarker(marker(
            'https://github.com/o/r/releases/download/v1/Onyx-Setup.exe')),
        isNull,
      );
      // Navigation privée : le navigateur masque l'adresse.
      expect(InstallOrigin.serverUrlFromMarker(marker('about:internet')),
          isNull);
      expect(InstallOrigin.serverUrlFromMarker('[ZoneTransfer]\r\nZoneId=3'),
          isNull);
      expect(InstallOrigin.serverUrlFromMarker(''), isNull);
    });
  });

  group('adresse par défaut du client', () {
    setUp(() {
      InstallOrigin.overrideMarkerForTest(() async => marker(
          'https://onyx.example.com/api/downloads/Onyx-1.2.0-windows.exe'));
    });
    tearDown(InstallOrigin.resetForTest);

    test('une première ouverture part de l\'origine de l\'installeur',
        () async {
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient();
      await api.initialize();

      expect(api.baseUrl, 'https://onyx.example.com');
      expect(api.hasChosenServer, isTrue);
    });

    test('une adresse déjà saisie l\'emporte sur l\'origine', () async {
      SharedPreferences.setMockInitialValues(
          {'server_url': 'http://nas:8080'});
      final api = ApiClient();
      await api.initialize();

      expect(api.baseUrl, 'http://nas:8080');
    });

    test('un marqueur illisible laisse le défaut de la plateforme', () async {
      InstallOrigin.overrideMarkerForTest(() async => throw Exception('acl'));
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient();
      await api.initialize();

      expect(api.hasChosenServer, isFalse);
    });
  });
}
