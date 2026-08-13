import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';

void main() {
  group('NextEpisodeResponse', () {
    test('reads the next episode when the server holds one', () {
      final response = NextEpisodeResponse.fromJson({
        'has_next': true,
        'episode': {
          'id': 42,
          'type': 'episode',
          'title': 'Episode 1',
          'duration': 1200,
          'file_path': '/ep.mkv',
        },
      });

      expect(response.hasNext, isTrue);
      expect(response.episode?.media.id, 42);
      expect(response.nextSeason, isNull);
    });

    test('reads the missing next season when there is no episode left', () {
      final response = NextEpisodeResponse.fromJson({
        'has_next': false,
        'next_season': {
          'show_id': 7,
          'show_tmdb_id': 1399,
          'show_title': 'Lioness',
          'number': 4,
          'name': 'Saison 4',
          'overview': 'Résumé',
          'poster_url': 'https://image.tmdb.org/t/p/w500/x.jpg',
          'episode_count': 10,
          'request_status': 'unknown',
          'can_request': true,
        },
      });

      expect(response.hasNext, isFalse);
      expect(response.episode, isNull);
      expect(response.nextSeason?.number, 4);
      expect(response.nextSeason?.canRequest, isTrue);
      expect(response.nextSeason?.isRequested, isFalse);
    });

    // MediaHub unreachable, or show unmatched: the server omits next_season
    // entirely so no card is shown at all.
    test('has no next season when the server omits it', () {
      final response = NextEpisodeResponse.fromJson({'has_next': false});

      expect(response.hasNext, isFalse);
      expect(response.nextSeason, isNull);
    });
  });

  group('NextSeason', () {
    NextSeason season(String status, {bool canRequest = false}) {
      return NextSeason.fromJson({
        'number': 4,
        'name': 'Saison 4',
        'request_status': status,
        'can_request': canRequest,
      });
    }

    test('a pending season reads as requested', () {
      expect(season('pending').isRequested, isTrue);
      expect(season('processing').isRequested, isTrue);
      expect(season('unknown', canRequest: true).isRequested, isFalse);
    });

    test('a missing request status defaults to non-requestable', () {
      final parsed = NextSeason.fromJson({'number': 4, 'name': 'Saison 4'});

      expect(parsed.canRequest, isFalse);
      expect(parsed.requestStatus, 'unavailable');
    });

    test('copyWith confirms the request without losing the rest', () {
      final confirmed = season('unknown', canRequest: true)
          .copyWith(requestStatus: 'pending', canRequest: false);

      expect(confirmed.isRequested, isTrue);
      expect(confirmed.canRequest, isFalse);
      expect(confirmed.number, 4);
      expect(confirmed.name, 'Saison 4');
    });
  });
}
