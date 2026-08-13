/// Opens a URL outside the app — the browser on desktop, a new tab on web.
library;
///
/// Returns false when the platform has no way to do it, so the caller can fall
/// back to showing the link for the user to copy.
export 'external_url_io.dart'
    if (dart.library.js_interop) 'external_url_web.dart';
