/// Web implementation of the platform predicates — see `app_platform.dart`.
///
/// Every OS predicate is false: the browser is its own platform, and the
/// features these flags guard (window chrome, media keys, mpv properties) do
/// not exist here. Code that needs a browser-specific branch tests [isWeb].
abstract final class AppPlatform {
  static const bool isWeb = true;

  static const bool isMacOS = false;
  static const bool isWindows = false;
  static const bool isLinux = false;
  static const bool isAndroid = false;
  static const bool isIOS = false;

  static const bool isDesktop = false;
  static const bool isMobile = false;
}
