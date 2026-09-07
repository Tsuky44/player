import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/offline_chrome.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/models/player_layout.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Un client pointé sur le serveur d'où viennent les médias du manifeste.
///
/// Ce n'est pas un détail de mise en scène : depuis qu'un appareil peut tenir
/// plusieurs serveurs (ADR-0013), la liste des téléchargements est celle du
/// serveur actif — un `media_id` ne veut rien dire ailleurs.
class _ApiAtNas extends ApiClient {
  @override
  String get baseUrl => 'http://nas:8080';
}

/// Pointe le stockage applicatif vers un dossier jetable.
class _TempSupportDirectory extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempSupportDirectory(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Map<String, dynamic> _entry({
  required int mediaId,
  required String title,
  bool isFinished = false,
  int position = 0,
}) {
  return {
    'media_id': mediaId,
    'type': 'episode',
    'title': title,
    'file_name': 'video.mkv',
    'added_at': '2026-09-01T12:00:00.000Z',
    'show_title': 'Ma série',
    'show_id': 7,
    'server_url': 'http://nas:8080',
    'season_number': 1,
    'episode_number': mediaId,
    'duration': 2400,
    'status': 'completed',
    'bytes_received': 1000,
    'bytes_total': 1000,
    'position_seconds': position,
    'is_finished': isFinished,
    'needs_sync': false,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('onyx_offline_test');
    PathProviderPlatform.instance = _TempSupportDirectory(root.path);

    final store = Directory('${root.path}/onyx_offline')
      ..createSync(recursive: true);
    // Deux épisodes déjà rapatriés, dont un seul a réellement son fichier :
    // c'est ce qui distingue « présent au manifeste » de « lisible ».
    File('${store.path}/manifest.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'items': [
        _entry(mediaId: 1, title: 'Le pilote'),
        _entry(mediaId: 2, title: 'La suite', isFinished: true, position: 2400),
      ],
    }));
    Directory('${store.path}/1').createSync();
    File('${store.path}/1/video.mkv').writeAsStringSync('des octets');

    // La fiche de la série, écrite une fois et partagée par ses épisodes.
    Directory('${store.path}/shows/7').createSync(recursive: true);
    File('${store.path}/shows/7/details.json').writeAsStringSync(jsonEncode({
      'id': 7,
      'type': 'show',
      'title': 'Ma série',
      'overview': 'Un synopsis rapatrié avec les épisodes.',
      'genres': ['Drame', 'Science-fiction'],
      'number_of_seasons': 3,
      'vote_average': 8.4,
      'release_date': '2019-05-01',
    }));
    File('${store.path}/shows/7/poster.jpg').writeAsStringSync('jpeg');

    await DownloadManager.instance.initialize(_ApiAtNas());
  });

  tearDownAll(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('relit le manifeste au démarrage', () {
    final manager = DownloadManager.instance;
    expect(manager.isSupported, isTrue);
    expect(manager.isReady, isTrue);
    expect(manager.downloads.length, 2);
    expect(manager.entryFor(1)?.title, 'Le pilote');
  });

  test('ne propose à la lecture que ce qui est vraiment sur le disque', () {
    final manager = DownloadManager.instance;
    expect(manager.localVideoPath(1), endsWith('/1/video.mkv'));
    // Au manifeste mais pas sur le disque : le lecteur doit repasser par le
    // réseau plutôt qu'ouvrir un chemin qui n'existe pas.
    expect(manager.localVideoPath(2), isNull);
    expect(manager.localVideoPath(999), isNull);
  });

  test('la règle des 90 % marque vu sans attendre le serveur', () async {
    final manager = DownloadManager.instance;
    await manager.recordProgress(
      mediaId: 1,
      positionSeconds: 2200, // 91,6 % de 2400
      durationSeconds: 2400,
      isFinished: false,
    );

    final entry = manager.entryFor(1)!;
    expect(entry.isFinished, isTrue);
    expect(entry.positionSeconds, 2200);
    // Rien n'est parti vers le serveur : la lecture reste à rejouer.
    expect(entry.needsSync, isTrue);
    expect(manager.pendingSyncCount, 1);
  });

  test('un avancement déjà accepté par le serveur ne demande pas de rejeu',
      () async {
    final manager = DownloadManager.instance;
    await manager.recordProgress(
      mediaId: 1,
      positionSeconds: 120,
      durationSeconds: 2400,
      isFinished: false,
      syncedWithServer: true,
    );

    final entry = manager.entryFor(1)!;
    expect(entry.isFinished, isFalse);
    expect(entry.needsSync, isFalse);
    expect(manager.pendingSyncCount, 0);
  });

  test("un média absent du manifeste n'est pas créé par une progression",
      () async {
    final manager = DownloadManager.instance;
    await manager.recordProgress(
      mediaId: 4242,
      positionSeconds: 60,
      durationSeconds: 2400,
      isFinished: false,
    );
    expect(manager.entryFor(4242), isNull);
    expect(manager.downloads.length, 2);
  });

  test('la fiche de la série est relue et partagée par ses épisodes', () {
    final manager = DownloadManager.instance;

    final byShow = manager.detailsForShow(7);
    expect(byShow, isNotNull);
    expect(byShow!.title, 'Ma série');
    expect(byShow.numberOfSeasons, 3);
    expect(byShow.genres, contains('Science-fiction'));

    // Les deux épisodes renvoient à la même fiche : un épisode ne porte pas de
    // synopsis de série, c'est sa série qui en a un.
    expect(manager.offlineDetails(1)?.overview,
        'Un synopsis rapatrié avec les épisodes.');
    expect(manager.offlineDetails(2)?.id, 7);
    expect(manager.entryFor(1)?.infoId, 7);

    expect(manager.showPosterPath(7), endsWith('/shows/7/poster.jpg'));
    // Aucun logo n'a été rapatrié : l'appelant retombe sur le titre écrit.
    expect(manager.showLogoPath(7), isNull);
  });

  test('le playeur figé est celui du serveur d’où vient le média', () async {
    final manager = DownloadManager.instance;
    expect(manager.chromeFor(1), isNull);

    await manager.rememberChrome(OfflineChrome(
      serverUrl: 'http://nas:8080',
      presetId: 'preset-42',
      name: 'Mon playeur',
      useModular: true,
      config: PlayerLayoutConfig.fixed(FixedChromeId.emby),
      savedAt: DateTime.utc(2026, 9, 3),
    ));

    final chrome = manager.chromeFor(1);
    expect(chrome, isNotNull);
    expect(chrome!.presetId, 'preset-42');
    expect(chrome.useModular, isTrue);
    expect(chrome.config.fixedChrome, FixedChromeId.emby);

    // Écrit sur le disque, pas seulement en mémoire : c'est justement au
    // démarrage suivant, hors ligne, qu'il servira.
    final saved = jsonDecode(
      File('${root.path}/onyx_offline/chromes.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(saved.keys, contains('http://nas:8080'));
    expect(
      OfflineChrome.fromJson(
        Map<String, dynamic>.from(saved['http://nas:8080'] as Map),
      ).config.fixedChrome,
      FixedChromeId.emby,
    );
  });

  test('une adresse de serveur ne varie pas selon sa barre oblique finale', () {
    expect(OfflineChrome.normalizeServerUrl('http://nas:8080/'),
        'http://nas:8080');
    expect(OfflineChrome.normalizeServerUrl('  http://nas:8080//  '),
        'http://nas:8080');
  });

  test('le ménage des vus efface le média et son dossier', () async {
    final manager = DownloadManager.instance;
    await manager.recordProgress(
      mediaId: 1,
      positionSeconds: 2400,
      durationSeconds: 2400,
      isFinished: true,
      syncedWithServer: true,
    );

    final deleted = await manager.deleteWatched();
    expect(deleted, 2);
    expect(manager.downloads, isEmpty);
    expect(Directory('${root.path}/onyx_offline/1').existsSync(), isFalse);
    // Plus un seul épisode de la série : sa fiche n'a plus rien à décrire.
    expect(Directory('${root.path}/onyx_offline/shows/7').existsSync(), isFalse);
    expect(manager.detailsForShow(7), isNull);

    // Le manifeste réécrit doit refléter la suppression, pas seulement la
    // mémoire du processus.
    final manifest = jsonDecode(
      File('${root.path}/onyx_offline/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(manifest['items'], isEmpty);
  });

  test('un statut inconnu retombe sur la file plutôt que de faire échouer la relecture',
      () {
    final restored = OfflineDownload.fromJson({
      'media_id': 9,
      'type': 'movie',
      'title': 'Un film',
      'file_name': 'video.mp4',
      'added_at': '2026-09-01T12:00:00.000Z',
      'status': 'un_etat_dune_version_future',
    });
    expect(restored.status, DownloadStatus.queued);
  });
}
