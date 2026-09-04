import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/utils/format.dart';

OfflineDownload _episode({
  bool needsSync = false,
  bool isFinished = false,
  int position = 0,
}) {
  return OfflineDownload(
    mediaId: 42,
    type: MediaType.episode,
    title: 'Le pilote',
    fileName: 'video.mkv',
    addedAt: DateTime.utc(2026, 9, 1, 12),
    showTitle: 'Ma série',
    showId: 7,
    seasonNumber: 2,
    episodeNumber: 5,
    durationSeconds: 2400,
    positionSeconds: position,
    isFinished: isFinished,
    needsSync: needsSync,
    progressUpdatedAt: DateTime.utc(2026, 9, 2, 20),
    subtitles: const [
      OfflineSubtitle(lang: 'fr', name: 'Français', fileName: 'sub_fr.vtt'),
    ],
    tracks: const {'subtitles': []},
    status: DownloadStatus.completed,
    bytesReceived: 1500000000,
    bytesTotal: 1500000000,
  );
}

void main() {
  group('OfflineDownload', () {
    test('survives un aller-retour par le manifeste', () {
      final original = _episode(needsSync: true, position: 900);
      final restored = OfflineDownload.fromJson(original.toJson());

      expect(restored.mediaId, original.mediaId);
      expect(restored.type, MediaType.episode);
      expect(restored.showTitle, 'Ma série');
      expect(restored.seasonNumber, 2);
      expect(restored.episodeNumber, 5);
      expect(restored.positionSeconds, 900);
      // Le drapeau de resynchronisation est ce qui distingue une lecture hors
      // ligne d'une lecture déjà connue du serveur : le perdre à la relecture
      // du manifeste, c'est perdre le visionnage.
      expect(restored.needsSync, isTrue);
      expect(restored.progressUpdatedAt, original.progressUpdatedAt);
      expect(restored.subtitles.single.fileName, 'sub_fr.vtt');
      expect(restored.tracks, isNotNull);
      expect(restored.status, DownloadStatus.completed);
    });

    test('redonne au lecteur un épisode complet', () {
      final item = _episode(position: 600).toHomeMediaItem();

      expect(item.media.id, 42);
      expect(item.media.type, MediaType.episode);
      expect(item.showTitle, 'Ma série');
      expect(item.showId, 7);
      expect(item.currentPositionSeconds, 600);
      expect(item.effectiveDuration, 2400);
      expect(item.percentWatched, closeTo(0.25, 0.001));
    });

    test('le code d’épisode ne sort que lorsque les deux numéros sont connus',
        () {
      expect(_episode().episodeCode, 'S2E05');

      final movie = OfflineDownload(
        mediaId: 1,
        type: MediaType.movie,
        title: 'Un film',
        fileName: 'video.mp4',
        addedAt: DateTime.utc(2026, 9, 1),
      );
      expect(movie.episodeCode, isNull);
      expect(movie.groupTitle, 'Un film');
    });

    test('la progression reste indéterminée tant que la taille est inconnue',
        () {
      final queued = OfflineDownload(
        mediaId: 1,
        type: MediaType.movie,
        title: 'Un film',
        fileName: 'video.mp4',
        addedAt: DateTime.utc(2026, 9, 1),
        bytesReceived: 1000,
      );
      // Une barre à zéro dirait « rien n'est arrivé », ce qui est faux.
      expect(queued.progress, isNull);

      expect(queued.copyWith(bytesTotal: 4000).progress, closeTo(0.25, 0.001));
      expect(_episode().progress, 1);
    });

    test('copyWith peut effacer une erreur sans toucher au reste', () {
      final failed = _episode().copyWith(
        status: DownloadStatus.failed,
        error: 'Serveur injoignable',
      );
      expect(failed.error, 'Serveur injoignable');

      final retried = failed.copyWith(status: DownloadStatus.queued, error: null);
      expect(retried.error, isNull);
      expect(retried.title, failed.title);
      expect(retried.bytesReceived, failed.bytesReceived);
    });
  });

  group('formatBytes', () {
    test('passe à l’échelle lisible', () {
      expect(formatBytes(0), '0 Mo');
      expect(formatBytes(999), '999 o');
      expect(formatBytes(1500), '2 Ko');
      expect(formatBytes(1500000), '2 Mo');
      expect(formatBytes(1500000000), '1,5 Go');
    });
  });
}
