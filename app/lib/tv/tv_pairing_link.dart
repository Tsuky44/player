/// The `?tv=CODE` half of the QR flow.
///
/// Scanning the code on the television opens the web app at the server's own
/// address with the pairing code in the query string. The app boots, signs the
/// user in if it has to, and only then is there a session to approve with — so
/// the code cannot be acted on at the moment it arrives. It is parked here
/// until the shell is up, and taken exactly once.
abstract final class TvPairingLink {
  static String? _pending;
  static String? _origin;

  /// Reads the launch URL. A no-op off the web, where [Uri.base] is a file
  /// path and carries no query string.
  static void capture() {
    final code = Uri.base.queryParameters['tv'];
    if (code == null || code.trim().isEmpty) return;

    _pending = code.trim();

    // The address that served this page *is* the server the television is
    // waiting on. Remembering it is what makes the scan work on a phone whose
    // app is pointed somewhere else, or nowhere at all: the code only exists on
    // one server, and looking it up on another is a guaranteed "code inconnu".
    final base = Uri.base;
    if (base.hasScheme && base.host.isNotEmpty) {
      _origin = base.origin;
    }
  }

  static bool get hasPending => _pending != null;

  /// The server the scanned link came from, when the launch URL had one.
  static String? get origin => _origin;

  /// Hands the code over and forgets it, so a later rebuild of the shell does
  /// not re-open the approval screen behind the user.
  static String? take() {
    final code = _pending;
    _pending = null;
    return code;
  }
}
