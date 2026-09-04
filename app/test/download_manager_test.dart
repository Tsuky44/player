import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

    await DownloadManager.instance.initialize(ApiClient());
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
