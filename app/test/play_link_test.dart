import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/navigation/play_link.dart';

void main() {
  group('PlayLink.parse', () {
    test('un film', () {
      expect(PlayLink.parse(Uri.parse('onyx://play?tmdbId=603&type=movie')),
          (MediaType.movie, 603));
    });

    test('une série, nommée tv ou show', () {
      expect(PlayLink.parse(Uri.parse('onyx://play?tmdbId=1399&type=tv')),
          (MediaType.show, 1399));
      expect(PlayLink.parse(Uri.parse('onyx://play?tmdbId=1399&type=show')),
          (MediaType.show, 1399));
    });

    test('refuse un autre schéma, une autre action ou un lien incomplet', () {
      for (final raw in [
        'https://play?tmdbId=1&type=movie',
        'onyx://settings?tmdbId=1&type=movie',
        'onyx://play?type=movie',
        'onyx://play?tmdbId=abc&type=movie',
        'onyx://play?tmdbId=0&type=movie',
        'onyx://play?tmdbId=5',
        'onyx://play?tmdbId=5&type=music',
      ]) {
        expect(PlayLink.parse(Uri.parse(raw)), isNull, reason: raw);
      }
    });
  });
}
