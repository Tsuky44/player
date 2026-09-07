import 'dart:io' as io;

/// Native implementation of the platform predicates — see `app_platform.dart`.
abstract final class AppPlatform {
  static const bool isWeb = false;

  static bool get isMacOS => io.Platform.isMacOS;
  static bool get isWindows => io.Platform.isWindows;
  static bool get isLinux => io.Platform.isLinux;
  static bool get isAndroid => io.Platform.isAndroid;
  static bool get isIOS => io.Platform.isIOS;

  /// True on the three platforms that carry a resizable OS window.
  static bool get isDesktop => isWindows || isMacOS || isLinux;

  static bool get isMobile => isAndroid || isIOS;

  /// Comment cet appareil se nomme auprès d'un serveur qui ne le connaît pas
  /// encore — la ligne que lit l'administrateur d'une demande d'accès. Le nom
  /// de la machine serait plus parlant, mais le lire coûte une permission sur
  /// Android et une dépendance partout ailleurs, pour un libellé décoratif.
  static String get label {
    if (isMacOS) return 'Mac';
    if (isWindows) return 'PC Windows';
    if (isLinux) return 'PC Linux';
    if (isAndroid) return 'Appareil Android';
    if (isIOS) return 'iPhone / iPad';
    return 'Appareil';
  }
}
