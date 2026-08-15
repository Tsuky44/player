import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/media_details_cache.dart';

/// Counts calls and lets a test hold a request open, so "did this hit the
/// network?" is observable rather than inferred from timing.
class _FakeApi extends ApiClient {
  int calls = 0;
  final List<int> requestedIds = [];
  Completer<MediaDetails>? gate;

  /// Id the server answers with, when it differs from the one asked for —
  /// duplicate show rows are resolved to a canonical id server-side.
  int? canonicalId;

  bool fail = false;

  @override
  Future<MediaDetails> getMediaDetails(int mediaId) {
    calls++;
    requestedIds.add(mediaId);
    if (fail) return Future.error(StateError('offline'));
    final details = MediaDetails(
      id: canonicalId ?? mediaId,
      type: MediaType.movie,
      title: 'Titre $mediaId',
      logoUrl: 'https://image.tmdb.org/t/p/original/logo$mediaId.png',
    );
    final held = gate;
    if (held != null) return held.future;
    return Future.value(details);
  }
}

void main() {
  late _FakeApi api;

  setUp(() {
    MediaDetailsCache.clear();
    api = _FakeApi();
  });

  tearDown(MediaDetailsCache.clear);

  test('a second reader is served from cache instead of the network', () async {
    await MediaDetailsCache.load(api, 7);
    await MediaDetailsCache.load(api, 7);

    expect(api.calls, 1);
    expect(MediaDetailsCache.peek(7)?.title, 'Titre 7');
  });

  test('concurrent readers share one request', () async {
    // The detail page and the player can both ask on the same frame.
    final gate = Completer<MediaDetails>();
    api.gate = gate;

    final first = MediaDetailsCache.load(api, 3);
    final second = MediaDetailsCache.load(api, 3);

    expect(api.calls, 1);

    gate.complete(MediaDetails(id: 3, type: MediaType.movie, title: 'Titre 3'));
    await Future.wait([first, second]);
    expect(api.calls, 1);
  });

  test('the payload is filed under the canonical id the server returns',
      () async {
    // A duplicate show row: the page opens with id 12, the server answers 4.
    // The player may then ask with either one and must not refetch.
    api.canonicalId = 4;
    await MediaDetailsCache.load(api, 12);

    expect(MediaDetailsCache.peek(12), isNotNull);
    expect(MediaDetailsCache.peek(4), isNotNull);

    await MediaDetailsCache.load(api, 4);
    expect(api.calls, 1);
  });

  test('the player reads the logo without touching the network', () async {
    await MediaDetailsCache.load(api, 9);
    api.calls = 0;

    expect(MediaDetailsCache.peekLogo(9),
        'https://image.tmdb.org/t/p/original/logo9.png');
    expect(await MediaDetailsCache.resolveLogo(api, 9),
        'https://image.tmdb.org/t/p/original/logo9.png');
    expect(api.calls, 0);
  });

  test('a media with no logo is remembered as such, not retried', () async {
    // A cached "this title has no logo" is a real answer and must stop further
    // requests — otherwise every playback re-asks for a null.
    MediaDetailsCache.remember(
      5,
      MediaDetails(id: 5, type: MediaType.movie, title: 'Sans logo'),
    );

    expect(await MediaDetailsCache.resolveLogo(api, 5), isNull);
    expect(api.calls, 0);
  });

  test('a failed lookup is not cached as an absent logo', () async {
    api.fail = true;

    expect(await MediaDetailsCache.resolveLogo(api, 11), isNull);
    expect(MediaDetailsCache.peek(11), isNull);

    // The next attempt goes back to the network rather than serving the
    // failure for the rest of the session.
    api.fail = false;
    expect(await MediaDetailsCache.resolveLogo(api, 11),
        'https://image.tmdb.org/t/p/original/logo11.png');
  });

  test('invalidate forces the next read back to the network', () async {
    await MediaDetailsCache.load(api, 2);
    MediaDetailsCache.invalidate(2);

    expect(MediaDetailsCache.peek(2), isNull);
    await MediaDetailsCache.load(api, 2);
    expect(api.calls, 2);
  });

  test('forceRefresh bypasses a fresh entry', () async {
    await MediaDetailsCache.load(api, 6);
    await MediaDetailsCache.load(api, 6, forceRefresh: true);

    expect(api.calls, 2);
  });
}
