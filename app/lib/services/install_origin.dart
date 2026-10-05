/// D'où vient l'installeur qui a posé cette app — voir ADR-0042.
///
/// L'installeur se télécharge presque toujours depuis le serveur qu'on va
/// utiliser (`https://mon-serveur/api/downloads/Onyx-…-windows.exe`). Windows
/// note cette adresse sur le fichier téléchargé, l'installeur la recopie, et
/// l'écran de connexion s'ouvre avec l'adresse du serveur déjà remplie au lieu
/// de `http://127.0.0.1:8080`.
library;

import 'dart:convert';

import '../models/server_account.dart';
import 'install_origin_io.dart'
    if (dart.library.js_interop) 'install_origin_web.dart';

abstract final class InstallOrigin {
  /// La route qui sert les installeurs (`server/handlers/downloads.go`). Tout
  /// ce qui la précède dans l'adresse de téléchargement est la racine du
  /// serveur, sous-chemin de reverse proxy compris.
  static const _downloadsRoute = '/api/downloads/';

  static Future<String?> Function() _readMarker = readInstallOriginMarker;

  /// L'adresse du serveur d'où l'installeur a été téléchargé, ou `null` quand
  /// on ne la connaît pas : autre plateforme que Windows, installeur venu
  /// d'ailleurs (page GitHub, clé USB), navigation privée.
  ///
  /// Une lecture qui échoue vaut « inconnu » : c'est un confort de saisie, il
  /// ne doit jamais empêcher l'app de démarrer.
  static Future<String?> serverUrl() async {
    try {
      final marker = await _readMarker();
      return marker == null ? null : serverUrlFromMarker(marker);
    } catch (_) {
      return null;
    }
  }

  /// Extrait l'adresse du serveur du marqueur `Zone.Identifier` de Windows :
  ///
  /// ```
  /// [ZoneTransfer]
  /// ZoneId=3
  /// HostUrl=https://onyx.example.com/api/downloads/Onyx-1.2.0-windows.exe
  /// ```
  ///
  /// Seule une adresse http(s) passant par la route des installeurs est
  /// retenue : un fichier pris sur GitHub ne désigne aucun serveur Onyx, et
  /// préremplir `https://github.com` serait pire que ne rien préremplir.
  static String? serverUrlFromMarker(String marker) {
    for (final rawLine in const LineSplitter().convert(marker)) {
      final line = rawLine.trim();
      if (!line.startsWith('HostUrl=')) continue;

      final uri = Uri.tryParse(line.substring('HostUrl='.length).trim());
      if (uri == null || uri.host.isEmpty) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;

      final route = uri.path.indexOf(_downloadsRoute);
      if (route < 0) return null;
      return ServerAccount.normalizeUrl(
        '${uri.origin}${uri.path.substring(0, route)}',
      );
    }
    return null;
  }

  static void overrideMarkerForTest(Future<String?> Function() read) =>
      _readMarker = read;

  static void resetForTest() => _readMarker = readInstallOriginMarker;
}
