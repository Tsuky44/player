/// Platform predicates that are safe to evaluate on every target.
library;
///
/// `dart:io` cannot be imported in a web build at all — it is a compile error,
/// not a runtime one — so `Platform.isMacOS` and friends are unreachable from
/// shared code. This facade resolves to the `dart:io` implementation everywhere
/// except web, where every OS predicate is simply false.
///
/// That "all false" answer is the right one for this codebase: every existing
/// `Platform.isX` check guards native window chrome, media keys or mpv
/// properties — things a browser has no equivalent for.
export 'app_platform_io.dart'
    if (dart.library.js_interop) 'app_platform_web.dart';
