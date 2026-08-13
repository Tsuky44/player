/// Desktop window operations, behind a facade so shared code can call them
/// unconditionally.
library;
///
/// `package:window_manager` imports `dart:io` in its top-level library, so a
/// direct import anywhere in the widget tree breaks the web compile even when
/// the call site is already guarded by a runtime `isDesktop` check. Routing
/// every use through this facade keeps the offending import inside the one file
/// the web build never sees.
export 'window_controls_io.dart'
    if (dart.library.js_interop) 'window_controls_web.dart';
