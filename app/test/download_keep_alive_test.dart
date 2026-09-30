import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/services/downloads/download_keep_alive.dart';

OfflineDownload _entry(
  int id,
  DownloadStatus status, {
  int received = 0,
  int total = 0,
}) =>
    OfflineDownload(
      mediaId: id,
      type: MediaType.episode,
      title: 'Épisode $id',
      fileName: 'video.mkv',
      addedAt: DateTime(2026, 9, 30),
      showTitle: 'Ma série',
      seasonNumber: 1,
      episodeNumber: id,
      status: status,
      bytesReceived: received,
      bytesTotal: total,
    );

void main() {
  test('la notification dit quel épisode descend et où il en est', () {
    final notice = downloadNoticeFor([
      _entry(3, DownloadStatus.downloading,
          received: 1400000000, total: 2800000000),
      _entry(4, DownloadStatus.queued),
      _entry(5, DownloadStatus.queued),
      _entry(1, DownloadStatus.completed),
    ], transferring: true);
    expect(notice?.title, 'Ma série · S1E03');
    expect(notice?.text, '1,4 Go sur 2,8 Go · 2 en attente');
    expect(notice?.percent, 50);
  });

  test('le service tient entre deux épisodes', () {
    // Rien ne descend à cet instant, mais la file tourne : l'arrêter ici,
    // écran éteint, et Android refuserait de le relancer pour le suivant.
    final notice = downloadNoticeFor(
      [_entry(4, DownloadStatus.queued), _entry(3, DownloadStatus.completed)],
      transferring: true,
    );
    expect(notice, isNotNull);
    expect(notice!.percent, -1);
  });

  test('une file à l’arrêt ne garde rien éveillé', () {
    // Réseau refusé ou serveur perdu : la file attend un événement, pas un
    // processeur.
    expect(
      downloadNoticeFor([_entry(4, DownloadStatus.queued)],
          transferring: false),
      isNull,
    );
    expect(
      downloadNoticeFor([_entry(1, DownloadStatus.completed)],
          transferring: true),
      isNull,
    );
  });

  test('une taille inconnue donne une barre indéterminée, pas zéro', () {
    final notice = downloadNoticeFor(
        [_entry(3, DownloadStatus.downloading)],
        transferring: true);
    expect(notice?.percent, -1);
    expect(notice?.text, 'Téléchargement…');
  });
}
