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
}
