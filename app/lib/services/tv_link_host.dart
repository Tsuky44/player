/// The television's half of direct linking — see the io/web implementations.
///
/// A television installed today has no server address and no keyboard to be
/// given one, and the pairing flow cannot help: opening a pairing is a call to
/// the very server it is missing. Discovery covers the easy networks and leaves
/// the rest on an on-screen keyboard.
///
/// So the television stops asking and starts offering. It opens a listener on
/// the local network, shows a QR pointing at itself, and waits for the phone —
/// which knows the server and is already signed in — to deliver both.
///
/// The types the screen works with live in `tv_link.dart`, which is not
/// conditional: only the transport differs per platform.
library;

export 'tv_link_host_io.dart'
    if (dart.library.js_interop) 'tv_link_host_web.dart';
