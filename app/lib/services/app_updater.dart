/// In-place application update — see `app_updater_io.dart`.
library;
///
/// `dart:io` cannot be imported in a web build at all, and there is nothing to
/// update there anyway (the browser always loads the current bundle), so the
/// web side resolves to a stub that reports the feature as unsupported.
export 'app_updater_io.dart'
    if (dart.library.js_interop) 'app_updater_web.dart';
