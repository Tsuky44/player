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

  group('size for the slot', () {
    const posterW500 =
        'https://image.tmdb.org/t/p/w500/kqjL17yufvn9OVLyXYpvtyrFfak.jpg';

    test('picks the smallest TMDB width that covers the physical width', () {
      // Une carte de téléphone : 112 px logiques à densité 3.
      expect(tmdbUrlForWidth(posterW500, 336),
          'https://image.tmdb.org/t/p/w342/kqjL17yufvn9OVLyXYpvtyrFfak.jpg');
      // Une carte de TV à densité 1.
      expect(tmdbUrlForWidth(posterW500, 150),
          'https://image.tmdb.org/t/p/w154/kqjL17yufvn9OVLyXYpvtyrFfak.jpg');
    });

    test('never goes above the size the caller asked for', () {
      // La taille demandée est un plafond : un fond de 1920 px reste en w500.
      expect(tmdbUrlForWidth(posterW500, 1920), posterW500);
      expect(tmdbUrlForWidth(posterW500, 480), posterW500);
    });

    test('original comes down too, h-sizes and other hosts stay', () {
      expect(tmdbUrlForWidth(logoOriginal, 400),
          'https://image.tmdb.org/t/p/w500/aX9lSBQmR8Vd6dNM1Sm5V4LtcuS.png');
      expect(tmdbUrlForWidth(profileH632, 100), profileH632);
      const local = 'https://media.example.com/covers/w300/film.jpg';
      expect(tmdbUrlForWidth(local, 100), local);
    });

    test('reads the served width back', () {
      expect(tmdbServedWidth(posterW500), 500);
      expect(tmdbServedWidth(logoOriginal), isNull);
      expect(tmdbServedWidth(profileH632), isNull);
    });
  });

  group('detail backdrop', () {
    const backdropW780 =
        'https://image.tmdb.org/t/p/w780/fNG7i7RqMErkcqhohV2a6cV1Ehy.jpg';

    test('a full-page backdrop is capped at original, not w1280', () {
      // Sur une fenêtre de 2000 px, w1280 était agrandi et se voyait flou.
      final url = detailBackdropUrl(backdropW780)!;
      expect(url,
          'https://image.tmdb.org/t/p/original/fNG7i7RqMErkcqhohV2a6cV1Ehy.jpg');
      expect(tmdbUrlForWidth(url, 2000), url);
      expect(tmdbUrlForWidth(url, 1200),
          'https://image.tmdb.org/t/p/w1280/fNG7i7RqMErkcqhohV2a6cV1Ehy.jpg');
    });

    test('lite mode never decodes original', () {
      final url = detailBackdropUrl(backdropW780)!;
      expect(tmdbUrlForWidth(url, 3840, allowOriginal: false),
          'https://image.tmdb.org/t/p/w1280/fNG7i7RqMErkcqhohV2a6cV1Ehy.jpg');
    });
  });
}
