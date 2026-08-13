import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';

void main() {
  Map<String, dynamic> seasonJson({
    required int id,
    required int number,
    bool? isAvailable,
    String? requestStatus,
    bool? canRequest,
    int? episodeCount,
  }) {
    return {
      'id': id,
      'type': 'season',
      'title': 'Saison $number',
      'season_number': number,
      'duration': 0,
      if (isAvailable != null) 'is_available': isAvailable,
      if (requestStatus != null) 'request_status': requestStatus,
      if (canRequest != null) 'can_request': canRequest,
      if (episodeCount != null) 'episode_count': episodeCount,
    };
  }

  group('Media season request state', () {
    test('a missing season carries its request status and episode count', () {
      final season = Media.fromJson(seasonJson(
        id: 0,
        number: 4,
        isAvailable: false,
        requestStatus: 'unknown',
        canRequest: true,
        episodeCount: 10,
      ));

      expect(season.isAvailable, isFalse);
      expect(season.canRequest, isTrue);
      expect(season.isRequested, isFalse);
      expect(season.episodeCount, 10);
    });

    test('a pending season is requested and no longer requestable', () {
      final season = Media.fromJson(seasonJson(
        id: 0,
        number: 4,
        isAvailable: false,
        requestStatus: 'pending',
        canRequest: false,
      ));

      expect(season.isRequested, isTrue);
      expect(season.canRequest, isFalse);
    });

    // The whole point of the server sending can_request: an unreachable
    // MediaHub must never let the UI offer a button that would fail.
    test('an unavailable MediaHub leaves the season non-requestable', () {
      final season = Media.fromJson(seasonJson(
        id: 0,
        number: 4,
        isAvailable: false,
        requestStatus: 'unavailable',
        canRequest: false,
      ));

      expect(season.canRequest, isFalse);
      expect(season.isRequested, isFalse);
    });

    test('payloads without the request fields default to non-requestable', () {
      final season = Media.fromJson(seasonJson(id: 12, number: 1));

      expect(season.isAvailable, isTrue);
      expect(season.canRequest, isFalse);
      expect(season.requestStatus, isNull);
    });

    test('copyWith flips a season to requested without touching the rest', () {
      final season = Media.fromJson(seasonJson(
        id: 0,
        number: 4,
        isAvailable: false,
        requestStatus: 'unknown',
        canRequest: true,
        episodeCount: 10,
      ));

      final requested =
          season.copyWith(requestStatus: 'pending', canRequest: false);

      expect(requested.isRequested, isTrue);
      expect(requested.canRequest, isFalse);
      expect(requested.title, season.title);
      expect(requested.seasonNumber, 4);
      expect(requested.episodeCount, 10);
      expect(requested.isAvailable, isFalse);
    });
  });
}
