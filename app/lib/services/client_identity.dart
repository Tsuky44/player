import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../tv/tv_mode.dart';
import '../utils/app_platform.dart';

/// Comment cet appareil se présente au serveur, sur chaque requête.
///
/// Le serveur s'en sert pour la liste des appareils connectés et pour le
/// tableau de bord : « Salon · Android TV 1.4.2 » dit à un administrateur qui
/// regarde quoi, là où un jeton de session ne dit rien.
abstract final class ClientIdentity {
  static const deviceHeader = 'X-Onyx-Device';
  static const clientHeader = 'X-Onyx-Client';

  static String _version = '';

  /// Lit la version de l'app. Sans elle, l'en-tête dit seulement la plateforme.
  static Future<void> initialize() async {
    try {
      _version = AppPlatform.isTvOS
          ? await _tvosVersion()
          : (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      _version = '';
    }
  }

  /// `package_info_plus` n'a pas de portage tvOS compatible avec la version
  /// épinglée ici (voir pubspec.yaml) : l'hôte tvOS lit lui-même
  /// `CFBundleShortVersionString`, sur le canal qui donne déjà le nom de
  /// l'appareil.
  static Future<String> _tvosVersion() async =>
      await const MethodChannel('onyx/device')
          .invokeMethod<String>('appVersion') ??
      '';

  static String get version => _version;

  static String get platform {
    if (AppPlatform.isWeb) return 'Web';
    if (AppPlatform.isAndroid) return TvMode.isTv ? 'Android TV' : 'Android';
    if (AppPlatform.isIOS) return 'iOS';
    if (AppPlatform.isTvOS) return 'tvOS';
    if (AppPlatform.isMacOS) return 'macOS';
    if (AppPlatform.isWindows) return 'Windows';
    if (AppPlatform.isLinux) return 'Linux';
    return 'Onyx';
  }

  /// Le nom le plus parlant dont on dispose : le modèle sur Android, le nom de
  /// la machine sur ordinateur, la famille d'appareil ailleurs.
  static String get deviceName {
    if (AppPlatform.isAndroid || AppPlatform.isIOS || AppPlatform.isTvOS) {
      return TvMode.deviceName;
    }
    if (AppPlatform.isDesktop && AppPlatform.hostName.isNotEmpty) {
      return AppPlatform.hostName;
    }
    return AppPlatform.label;
  }

  static String get client =>
      _version.isEmpty ? platform : '$platform $_version';

  /// En-têtes encodés : un nom avec des accents n'est pas valide tel quel dans
  /// un en-tête HTTP, et le serveur les décode.
  static Map<String, String> get headers => {
        deviceHeader: Uri.encodeComponent(deviceName),
        clientHeader: Uri.encodeComponent(client),
      };
}
