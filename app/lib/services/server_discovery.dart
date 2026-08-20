/// Finds the Onyx server on the local network — see the io/web implementations.
///
/// A television is installed fresh, in front of a QR screen, with no keyboard.
/// It has no server address and no reasonable way to be given one, so it looks
/// for the server itself before asking the user to type an IP with a D-pad.
library;

export 'server_discovery_io.dart'
    if (dart.library.js_interop) 'server_discovery_web.dart';
