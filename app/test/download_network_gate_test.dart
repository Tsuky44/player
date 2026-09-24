import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Ce qui décide qu'un transfert part ou attend : un réseau qui se paie à
/// l'octet retient la file entière sans rien perdre de ce qui a été demandé, et
/// un média effacé à la main ne revient pas tout seul.
class _ApiAtNas extends ApiClient {
  @override
  String get baseUrl => 'http://nas:8080';
}

class _TempSupportDirectory extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempSupportDirectory(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

HomeMediaItem _episode(int id, {required int number}) => HomeMediaItem(
      media: Media(
        id: id,
        type: MediaType.episode,
        title: 'Épisode $number',
        duration: 2400,
        seasonNumber: 1,
        episodeNumber: number,
        createdAt: DateTime(2026),
      ),
      currentPositionSeconds: 0,
      duration: 2400,
      isFinished: false,
      showId: 7,
      showTitle: 'Ma série',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final manager = DownloadManager.instance;
  var networkAllows = false;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('onyx_gate_test');
    PathProviderPlatform.instance = _TempSupportDirectory(root.path);
    // La garde est posée avant l'initialisation : le manifeste relu au
    // démarrage relance la file, et elle doit déjà être tenue.
    manager.transferGate = () => networkAllows;
    await manager.initialize(_ApiAtNas());
  });

  tearDownAll(() async {
    // Le dernier test rouvre le réseau : la file repart vers le NAS fictif et
    // écrit encore (dossiers de médias, manifeste) pendant qu'on efface. La
    // suppression échouait alors par intermittence en CI (« Directory not
    // empty »). On referme la file, puis on laisse ses dernières écritures
    // se poser avant de réessayer.
    networkAllows = false;
    manager.onNetworkChanged();
    for (var attempt = 0;; attempt++) {
      if (!await root.exists()) return;
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('un réseau facturé retient la file sans rien perdre', () async {
    final queued = await manager.downloadAll(
      [_episode(101, number: 1), _episode(102, number: 2)],
      showId: 7,
      showTitle: 'Ma série',
    );
    expect(queued, 2, reason: 'les deux sont bien demandés');

    // Le temps que la file tourne — et conclue qu'elle n'a pas le droit.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(manager.isHeldForNetwork, isTrue);
    expect(manager.queuedCount, 2);
    for (final id in [101, 102]) {
      expect(manager.entryFor(id)?.status, DownloadStatus.queued,
          reason: 'en file, pas en échec : rien n’a été tenté');
      expect(manager.entryFor(id)?.bytesReceived, 0);
    }
  });

  test('la même saison redemandée n’entre pas deux fois en file', () async {
    final again = await manager.downloadAll(
      [_episode(101, number: 1), _episode(103, number: 3)],
      showId: 7,
      showTitle: 'Ma série',
    );
    expect(again, 1, reason: 'seul le nouvel épisode compte');
    expect(manager.queuedCount, 3);
  });

  test('un épisode effacé sans avoir été vu ne revient pas tout seul',
      () async {
    await manager.delete(103);
    expect(manager.entryFor(103), isNull);
    expect(manager.isDeclined(103), isTrue);

    // La réserve automatique s'incline…
    final auto = await manager.downloadAll(
      [_episode(103, number: 3)],
      showId: 7,
      showTitle: 'Ma série',
      automatic: true,
    );
    expect(auto, 0);
    expect(manager.entryFor(103), isNull);

    // …mais pas un geste de l'utilisateur, qui répond à la question inverse.
    await manager.download(_episode(103, number: 3));
    expect(manager.entryFor(103)?.status, DownloadStatus.queued);
    expect(manager.isDeclined(103), isFalse);
  });

  test('le refus est écrit dans le manifeste, pour survivre au redémarrage',
      () async {
    await manager.delete(102);
    // Une écriture groupée suit la suppression ; on lui laisse le temps.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final manifest = File('${root.path}/onyx_offline/manifest.json');
    expect(await manifest.exists(), isTrue);
    final raw = jsonDecode(await manifest.readAsString()) as Map;
    expect(raw['declined'], contains('http://nas:8080|102'));
  });

  test('le réseau revient : la file repart', () async {
    networkAllows = true;
    manager.onNetworkChanged();
    expect(manager.isHeldForNetwork, isFalse);
  });
}
