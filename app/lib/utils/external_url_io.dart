import 'dart:io';

/// Native implementation — see `external_url.dart`.
///
/// Mobile has no shell command to hand a URL to, so it returns false and lets
/// the caller surface the link instead.
Future<bool> openExternalUrl(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [url]);
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
