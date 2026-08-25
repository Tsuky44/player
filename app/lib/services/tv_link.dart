import '../models/models.dart';

/// Direct linking, as the sign-in screen sees it.
///
/// The transport lives in `tv_link_host.dart`, which is native-only; this is
/// the part both the screen and its tests can talk to.
///
/// The shape is the whole idea: a television with no server address cannot open
/// a pairing, because opening one is a call to the server it is missing. So it
/// offers instead of asking — it starts listening, puts an address to itself in
/// a QR, and waits for a phone that has both halves to deliver them.
abstract interface class TvLinkSession {
  /// Opens the listener. Returns what the QR should carry, or null when this
  /// device has no usable address to offer.
  Future<TvLinkOffer?> start({required String deviceName});

  /// Resolves once a phone has delivered a server and a session.
  Future<TvLinkPayload> get linked;

  /// Closes the listener. Safe to call twice.
  Future<void> stop();
}

/// What the television puts in its QR code.
class TvLinkOffer {
  /// The whole payload of the QR: an address on this device, plus the one-time
  /// code any delivery has to carry.
  final String url;

  /// This device's address on the local network, shown under the QR so the
  /// user can see the app is offering something reachable.
  final String host;
  final int port;

  const TvLinkOffer({
    required this.url,
    required this.host,
    required this.port,
  });
}

/// What the phone delivered: where the server is, and a session on it.
class TvLinkPayload {
  final String serverUrl;
  final String token;
  final User user;

  const TvLinkPayload({
    required this.serverUrl,
    required this.token,
    required this.user,
  });
}
