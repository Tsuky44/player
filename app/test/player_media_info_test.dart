import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/player_media_info.dart';

Media _media(int id, MediaType type, String title, {int? parentId}) => Media(
      id: id,
      type: type,
      title: title,
      duration: 1200,
      parentId: parentId,
      createdAt: DateTime(2024),
    );

void main() {
  test('un épisode venu de l’accueil connaît sa série et son titre', () {
    final info = PlayerMediaInfo(HomeMediaItem(
      media: _media(7, MediaType.episode, 'S01E03', parentId: 4),
      currentPositionSeconds: 0,
      duration: 1300,
      isFinished: false,
      showTitle: 'Severance',
      showId: 2,
      episodeTitle: 'In Perpetuity',
    ));

    expect(info.isEpisode, isTrue);
    expect(info.showTitle, 'Severance');
    expect(info.overline, contains('In Perpetuity'));
    expect(info.seasonId, 4);
    // Le logo-titre est celui de la série, pas de l'épisode.
    expect(info.logoDetailsId, 2);
    expect(info.knownDurationSeconds, 1300);
  });

  test('un épisode venu d’une liste retrouve sa série par sa saison', () {
    final info =
        PlayerMediaInfo(_media(7, MediaType.episode, 'Pilote', parentId: 4));

    expect(info.showId, isNull);
    expect(info.logoDetailsId, 4);
    expect(info.knownDurationSeconds, 1200);
  });

  test('un film porte son propre logo', () {
    final info = PlayerMediaInfo(_media(9, MediaType.movie, 'Dune'));

    expect(info.isEpisode, isFalse);
    expect(info.showTitle, 'Dune');
    expect(info.logoDetailsId, 9);
  });

  test('la saison imposée par l’écran d’origine l’emporte pour la suite', () {
    final next = _media(8, MediaType.episode, 'Suite', parentId: 4);

    expect(
      PlayerMediaInfo(_media(7, MediaType.episode, 'Pilote'), seasonNumber: 3)
          .seasonNumberFor(next),
      3,
    );
    expect(
      PlayerMediaInfo(_media(7, MediaType.episode, 'Pilote'))
          .seasonNumberFor(next),
      next.effectiveSeasonNumber,
    );
  });
}
