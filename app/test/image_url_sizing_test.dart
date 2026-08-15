import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/poster_url.dart';

/// Artwork sizing is the difference between a logo that appears on the first
/// frame and one that arrives seconds late — the catalog hands back title
/// logos at `original`, a lossless PNG of several MB for an element drawn at
/// most 160 px high.
///
/// These tests pin two things: every helper rewrites the size segment whatever
/// form it arrives in, and helpers that feed the same artwork to two different
/// screens agree on one URL, so the second screen draws it from cache.
void main() {
  const logoOriginal =
      'https://image.tmdb.org/t/p/original/aX9lSBQmR8Vd6dNM1Sm5V4LtcuS.png';
  const posterW300 =
      'https://image.tmdb.org/t/p/w300/kqjL17yufvn9OVLyXYpvtyrFfak.jpg';
  const profileH632 =
      'https://image.tmdb.org/t/p/h632/2Sns5oMb356JNdBHgBETjIpRYy9.jpg';

  group('size rewriting', () {
    test('rewrites original, which the old w-only pattern left untouched', () {
      expect(
        logoImageUrl(logoOriginal),
        'https://image.tmdb.org/t/p/w500/aX9lSBQmR8Vd6dNM1Sm5V4LtcuS.png',
      );
    });

    test('rewrites an h-prefixed size', () {
      expect(
        castProfileUrl(profileH632),
        'https://image.tmdb.org/t/p/w185/2Sns5oMb356JNdBHgBETjIpRYy9.jpg',
      );
    });

    test('rewrites a w-prefixed size', () {
      expect(
        cardPosterUrl(posterW300),
        'https://image.tmdb.org/t/p/w500/kqjL17yufvn9OVLyXYpvtyrFfak.jpg',
      );
    });

    test('only touches the size segment, never the image path', () {
      // A path that itself contains something size-shaped must survive.
      const tricky = 'https://image.tmdb.org/t/p/original/w500original.png';
      expect(
        logoImageUrl(tricky),
        'https://image.tmdb.org/t/p/w500/w500original.png',
      );
    });

    test('leaves non-TMDB hosts alone', () {
      const local = 'https://media.example.com/covers/w300/film.jpg';
      expect(cardPosterUrl(local), local);
      expect(logoImageUrl(local), local);
      expect(backdropImageUrl(local), local);
    });

    test('resolves a server-relative path against the base URL', () {
      expect(
        cardPosterUrl('/static/poster.jpg',
            serverBaseUrl: 'https://onyx.example.com/'),
        'https://onyx.example.com/static/poster.jpg',
      );
    });

    test('null and blank stay null', () {
      expect(logoImageUrl(null), isNull);
      expect(castProfileUrl('   '), isNull);
      expect(backdropImageUrl(''), isNull);
    });
  });

  group('cross-screen reuse', () {
    test('the detail poster and the card poster are the same URL', () {
      // The detail header and the grid card show one image. Two URLs would
      // mean two downloads and two decodes of identical artwork.
      expect(detailPosterUrl(posterW300), cardPosterUrl(posterW300));
    });

    test('a poster already at w500 is not rewritten to something else', () {
      // Episode stills and season posters arrive at w500 from the server; the
      // card helper must leave them alone rather than churn the cache key.
      const stillW500 =
          'https://image.tmdb.org/t/p/w500/rMRAdlM2gJn0lLcHURV8ZOaTBzA.jpg';
      expect(cardPosterUrl(stillW500), stillW500);
    });

    test('normalising twice is a no-op', () {
      // The player feeds the cached payload's logo through the same helper the
      // detail header used. If that were not idempotent the two screens would
      // disagree and the player would re-download on every playback.
      final once = logoImageUrl(logoOriginal);
      expect(logoImageUrl(once), once);
      expect(castProfileUrl(castProfileUrl(profileH632)),
          castProfileUrl(profileH632));
    });
  });
}
