import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/widgets/global/season_download_plan.dart';

/// Ce que le bouton de saison compte et ce qu'un appui ajouterait.
void main() {
  HomeMediaItem episode(int id, {bool watched = false}) => HomeMediaItem(
        media: Media(
          id: id,
          type: MediaType.episode,
          title: 'Épisode $id',
          duration: 2400,
          seasonNumber: 1,
          episodeNumber: id,
          isAvailable: true,
          createdAt: DateTime(2026),
        ),
        currentPositionSeconds: 0,
        duration: 2400,
        isFinished: watched,
        showId: 7,
      );

  OfflineDownload entry(int id, DownloadStatus status) => OfflineDownload(
        mediaId: id,
        type: MediaType.episode,
        title: 'Épisode $id',
        fileName: 'video.mkv',
        addedAt: DateTime(2026),
        status: status,
      );

  // Vingt épisodes, les seize premiers vus.
  final season = [for (var i = 1; i <= 20; i++) episode(i, watched: i <= 16)];

  test('au repos, une saison entamée vise ses seuls non vus', () {
    final plan = SeasonDownloadPlan.of(season, (_) => null);

    expect(plan.nextBatchIsUnwatched, isTrue);
    expect(plan.unwatchedMissing, 4);
    expect(plan.nextBatch!.map((e) => e.media.id), [17, 18, 19, 20]);
  });

  test('le compteur du transfert porte sur les non vus lancés, pas la saison',
      () {
    final queued = {
      for (var id = 17; id <= 20; id++) id: entry(id, DownloadStatus.queued),
    };
    final plan = SeasonDownloadPlan.of(season, (id) => queued[id]);

    expect(plan.running, 4);
    expect('${plan.done}/${plan.requested}', '0/4');
    // Les non vus sont tous en route : rien à ajouter, et surtout pas les
    // seize déjà vus.
    expect(plan.nextBatch, isNull);
  });

  test('une fois les non vus là, « Compléter » propose les épisodes vus', () {
    final done = {
      for (var id = 17; id <= 20; id++) id: entry(id, DownloadStatus.completed),
    };
    final plan = SeasonDownloadPlan.of(season, (id) => done[id]);

    expect(plan.nextBatchIsUnwatched, isFalse);
    expect(plan.missing, 16);
    expect(plan.nextBatch, hasLength(20));
  });

  test('une saison jamais commencée vise tout, compteur compris', () {
    final fresh = [for (var i = 1; i <= 5; i++) episode(i)];
    final running = {1: entry(1, DownloadStatus.downloading)};
    final plan = SeasonDownloadPlan.of(fresh, (id) => running[id]);

    expect(plan.partlyWatched, isFalse);
    expect('${plan.done}/${plan.requested}', '0/1');
    expect(plan.nextBatch, hasLength(5));
  });
}
