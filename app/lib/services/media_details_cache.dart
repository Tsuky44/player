import '../models/models.dart';
import 'api_client.dart';

/// Process-wide memo of `/api/media/:id/details` payloads.
///
/// The details call is the page: title, logo, backdrop, synopsis, cast and
/// crew all arrive in it. Every screen that needed any part of it used to make
/// its own request — the movie page, the show page, and again the player just
/// to read one logo URL — so returning to a detail page you had opened a
/// minute earlier redrew from an empty state and waited on the network.
///
/// Holding the whole payload instead of a single field means the second reader
/// paints on its first frame. The entry is still revalidated in the background
/// (see [load]), so a fresh scan or a metadata fix shows up without a restart.
///
/// Only metadata lives here. Image bytes belong to the shared image store —
/// see `services/app_image_cache.dart`.
class MediaDetailsCache {
  MediaDetailsCache._();

  /// How long an entry is served without a network check. The server caches
  /// TMDB for 6 h, so anything shorter mostly re-reads its cache; anything
  /// longer outlives a rematch the user just performed.
  static const Duration ttl = Duration(minutes: 20);

  static final Map<int, _Entry> _entries = {};
  static int _generation = 0;

  /// In-flight requests, so several widgets asking at once share one call.
  static final Map<int, Future<MediaDetails>> _pending = {};

  /// The cached payload, whether fresh or stale, or null if never loaded.
  ///
  /// Callers render this immediately and let [load] refresh underneath.
  static MediaDetails? peek(int mediaId) => _entries[mediaId]?.details;

  /// True when [peek] is within [ttl] and no network check is warranted.
  static bool isFresh(int mediaId) {
    final entry = _entries[mediaId];
    return entry != null && DateTime.now().difference(entry.storedAt) < ttl;
  }

  /// Files a payload obtained elsewhere.
  ///
  /// Indexed under both ids because the server resolves a duplicate show or
  /// movie row to its canonical id: the page was opened with one id and the
  /// answer comes back carrying another, and the player will ask with either.
  static void remember(int requestedId, MediaDetails details) {
    final entry = _Entry(details, DateTime.now());
    if (requestedId > 0) _entries[requestedId] = entry;
    if (details.id > 0) _entries[details.id] = entry;
  }

  /// Drops an entry — after a metadata rematch, where the payload we hold is
  /// known to describe the wrong title.
  static void invalidate(int mediaId) {
    _entries.remove(mediaId);
    _pending.remove(mediaId);
  }

  static void clear() {
    _generation++;
    _entries.clear();
    _pending.clear();
  }

  /// Fetches the details, sharing one request between concurrent callers.
  ///
  /// A fresh entry short-circuits unless [forceRefresh] is set. A stale entry
  /// still goes to the network — callers that want the stale copy on screen in
  /// the meantime read [peek] first.
  static Future<MediaDetails> load(
    ApiClient api,
    int mediaId, {
    bool forceRefresh = false,
  }) {
    final cached = _entries[mediaId];
    if (!forceRefresh && cached != null && isFresh(mediaId)) {
      return Future.value(cached.details);
    }

    final inFlight = _pending[mediaId];
    if (inFlight != null && !forceRefresh) return inFlight;

    // The cleanup must not *return* the removed entry: `_pending` holds
    // futures, and `whenComplete` waits on any future its callback returns —
    // which here is this very request, so it would deadlock and the caller
    // would hang forever. A block body discards the value.
    final generation = _generation;
    late final Future<MediaDetails> request;
    request = api.getMediaDetails(mediaId).then((details) {
      if (generation == _generation && identical(_pending[mediaId], request)) {
        remember(mediaId, details);
      }
      return details;
    }).whenComplete(() {
      if (identical(_pending[mediaId], request)) _pending.remove(mediaId);
    });

    _pending[mediaId] = request;
    return request;
  }

  /// The title logo, from cache when we have it.
  ///
  /// Detail pages fill the cache on the way to playback, so the player chrome
  /// normally answers from [peekLogo] and opens on the logo rather than on the
  /// plain title.
  static String? peekLogo(int mediaId) => peek(mediaId)?.logoUrl;

  /// Resolves the logo, fetching the details once if they are not held yet.
  ///
  /// A failed lookup is not cached: a transient network error must not pin
  /// this media to "no logo" for the rest of the session.
  static Future<String?> resolveLogo(ApiClient api, int mediaId) async {
    if (mediaId <= 0) return null;
    final cached = peek(mediaId);
    if (cached != null) return cached.logoUrl;
    try {
      return (await load(api, mediaId)).logoUrl;
    } catch (_) {
      return null;
    }
  }
}

class _Entry {
  final MediaDetails details;
  final DateTime storedAt;

  const _Entry(this.details, this.storedAt);
}
