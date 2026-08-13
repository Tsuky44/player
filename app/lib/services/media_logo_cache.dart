import 'api_client.dart';

/// Process-wide memo of TMDB title-logo URLs, keyed by the media id whose
/// details carry the logo (the show id for an episode).
///
/// The logo is shown on detail pages and again in the player chrome. Without
/// this, opening the player re-ran `/api/media/:id/details` — a full details
/// payload fetched over the network just to read one URL — and the chrome sat
/// on the plain title until it landed. The URL for a given id does not change
/// between two screens of the same session, so the second reader takes it from
/// here and renders the logo on the first frame.
///
/// Only the URL is cached. The image bytes are handled by
/// `cached_network_image`, whose store is already shared across every surface
/// that renders the same URL.
class MediaLogoCache {
  MediaLogoCache._();

  /// A cached `null` is a real answer — "this media has no logo" — and must
  /// stop further requests, so absence is tracked by key presence, not value.
  static final Map<int, String?> _urls = {};

  /// In-flight requests, so several widgets asking at once share one call.
  static final Map<int, Future<String?>> _pending = {};

  /// Cached URL, or null when absent or not yet fetched. Callers that need to
  /// distinguish the two use [isCached].
  static String? peek(int mediaId) => _urls[mediaId];

  static bool isCached(int mediaId) => _urls.containsKey(mediaId);

  /// Records a URL already obtained elsewhere — detail screens call this with
  /// the details they just loaded, so the player never has to ask.
  static void remember(int mediaId, String? logoUrl) {
    if (mediaId <= 0) return;
    _urls[mediaId] = (logoUrl != null && logoUrl.isEmpty) ? null : logoUrl;
  }

  /// Returns the cached URL, fetching the media details once if needed.
  static Future<String?> resolve(ApiClient api, int mediaId) {
    if (mediaId <= 0) return Future.value(null);
    if (_urls.containsKey(mediaId)) return Future.value(_urls[mediaId]);

    final inFlight = _pending[mediaId];
    if (inFlight != null) return inFlight;

    final request = api.getMediaDetails(mediaId).then<String?>((details) {
      remember(mediaId, details.logoUrl);
      return _urls[mediaId];
    }).catchError((_) {
      // A failed lookup is not cached: a transient network error should not
      // pin this media to "no logo" for the rest of the session.
      return null;
    }).whenComplete(() => _pending.remove(mediaId));

    _pending[mediaId] = request;
    return request;
  }
}
