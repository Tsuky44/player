import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/hooks/use_episodes_panel.dart';
import 'package:onyx/services/api_client.dart';

HomeMediaItem _episode(int id, {String? showTitle}) => HomeMediaItem(
      media: Media(
        id: id,
        type: MediaType.episode,
        title: 'Épisode $id',
        duration: 1200,
        createdAt: DateTime(2024),
      ),
      currentPositionSeconds: 0,
      duration: 1200,
      isFinished: false,
      showTitle: showTitle,
    );

class _Api extends ApiClient {
  final Map<int, List<HomeMediaItem>> seasons = {
    4: [_episode(1, showTitle: 'Severance'), _episode(2), _episode(3)],
    5: [_episode(10)],
  };
  int seasonListCalls = 0;
  bool fail = false;

  @override
  Future<List<Media>> getShowSeasons(int showId) async {
    seasonListCalls++;
    return [
      Media(
        id: 4,
        type: MediaType.season,
        title: 'Saison 1',
        duration: 0,
        createdAt: DateTime(2024),
      ),
    ];
  }

  @override
  Future<List<HomeMediaItem>> getSeasonEpisodes(
    int seasonId, {
    bool includeMissing = false,
  }) async {
    if (fail) throw StateError('réseau');
    return seasons[seasonId] ?? const [];
  }
}

void main() {
  EpisodesPanelController panel(_Api api, {int episodeId = 2}) =>
      EpisodesPanelController(
        api: () => api,
        currentSeasonId: 4,
        currentShowId: 2,
        currentEpisodeId: episodeId,
      );

  test('le panneau s’ouvre sur la saison en cours', () async {
    final controller = panel(_Api());
    await controller.open(showTitle: 'Titre provisoire');

    expect(controller.isOpen, isTrue);
    expect(controller.isLoading, isFalse);
    expect(controller.selectedSeasonId, 4);
    expect(controller.episodes, hasLength(3));
    // Le titre de la série vient de la liste dès qu'elle le donne.
    expect(controller.showTitle, 'Severance');
  });

  test('changer de saison ne redemande pas la liste des saisons', () async {
    final api = _Api();
    final controller = panel(api);
    await controller.open(showTitle: 'Severance');
    await controller.selectSeason(5);

    expect(controller.selectedSeasonId, 5);
    expect(controller.episodes.single.media.id, 10);
    expect(api.seasonListCalls, 1);
  });

  test('un échec de chargement ne laisse pas le panneau tourner', () async {
    final api = _Api()..fail = true;
    final controller = panel(api);
    await controller.open(showTitle: 'Severance');

    expect(controller.isOpen, isTrue);
    expect(controller.isLoading, isFalse);
    expect(controller.episodes, isEmpty);
  });

  test('l’épisode précédent se lit dans la saison', () async {
    final controller = panel(_Api(), episodeId: 2);
    await controller.loadPreviousEpisode();
    expect(controller.previousEpisode?.media.id, 1);

    // Le premier de la saison n'en a pas : pas de saut de saison.
    final first = panel(_Api(), episodeId: 1);
    await first.loadPreviousEpisode();
    expect(first.previousEpisode, isNull);
  });

  test('fermer deux fois ne signale qu’une fermeture', () async {
    final controller = panel(_Api());
    await controller.open(showTitle: 'Severance');
    expect(controller.close(), isTrue);
    expect(controller.close(), isFalse);
  });

  test('une réponse arrivée après la destruction est ignorée', () async {
    final controller = panel(_Api());
    final opening = controller.open(showTitle: 'Severance');
    controller.dispose();
    await opening;
    expect(controller.episodes, isEmpty);
  });
}
