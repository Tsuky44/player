import 'dart:io';

import 'external_url_policy.dart';

/// Native implementation — see `external_url.dart`.
///
/// Mobile has no shell command to hand a URL to, so it returns false and lets
/// the caller surface the link instead.
Future<bool> openExternalUrl(String url) async {
  if (!isOpenableExternalUrl(url)) return false;
  try {
    if (Platform.isWindows) {
      // Pas `cmd /c start` : cmd relit la ligne et exécute ce qui suit un `&`
      // du lien. url.dll remet l'adresse au navigateur sans interpréteur.
      await Process.start(
          'rundll32.exe', ['url.dll,FileProtocolHandler', url]);
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
