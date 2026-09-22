import '../models/models.dart';
import 'api_client.dart';

/// Process-wide memo of `/api/media/:id/tracks`.
///
/// The track list is read from the file itself on the server, which makes it
/// the slowest call a movie page makes — and it used to be made twice per
/// visit, then again on every return to the page. A file's tracks only change
/// on a rescan, so an entry is served as-is for [ttl] and shared between
/// concurrent callers (the hover prefetch and the page it leads to).
///
/// Failures are never cached: an unreachable server must not pin a film to
/// "no track information" for the session.
class MediaTracksCache {
  MediaTracksCache._();

  static const Duration ttl = Duration(minutes: 30);

  static final Map<int, _Entry> _entries = {};
  static final Map<int, Future<MediaTracks>> _pending = {};
  static int _generation = 0;

  static MediaTracks? peek(int mediaId) => _entries[mediaId]?.tracks;

  static bool isFresh(int mediaId) {
    final entry = _entries[mediaId];
    return entry != null && DateTime.now().difference(entry.storedAt) < ttl;
  }

  static void invalidate(int mediaId) {
    _entries.remove(mediaId);
    _pending.remove(mediaId);
  }

  static void clear() {
    _generation++;
    _entries.clear();
    _pending.clear();
  }

  static Future<MediaTracks> load(
    ApiClient api,
    int mediaId, {
    bool forceRefresh = false,
  }) {
    final cached = _entries[mediaId];
    if (!forceRefresh && cached != null && isFresh(mediaId)) {
      return Future.value(cached.tracks);
    }

    final inFlight = _pending[mediaId];
    if (inFlight != null && !forceRefresh) return inFlight;

    // Block-bodied cleanup for the same reason as in MediaDetailsCache: a
    // `whenComplete` callback that returned the pending future would wait on
    // itself.
    final generation = _generation;
    late final Future<MediaTracks> request;
    request = api.getMediaTracks(mediaId).then((tracks) {
      if (generation == _generation && identical(_pending[mediaId], request)) {
        _entries[mediaId] = _Entry(tracks, DateTime.now());
      }
      return tracks;
    }).whenComplete(() {
      if (identical(_pending[mediaId], request)) _pending.remove(mediaId);
    });

    _pending[mediaId] = request;
    return request;
  }
}

class _Entry {
  final MediaTracks tracks;
  final DateTime storedAt;

  const _Entry(this.tracks, this.storedAt);
}
