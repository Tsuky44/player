import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/models/offline_download.dart';
import 'package:onyx/services/auto_download.dart';
import 'package:onyx/services/download_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La réserve d'avance : ce que l'app rapatrie toute seule pour qu'il y ait
/// toujours de quoi regarder sans réseau, et surtout ce qu'elle ne rapatrie pas.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const showId = 7;
  final preferences = DownloadPreferences.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await preferences.setMode(AutoDownloadMode.keepAhead);
    await preferences.setKeepAhead(4);
  });

  /// Une série de [count] épisodes chez le serveur, numérotés 101, 102…
  _Catalog catalogOf(int count, {Set<int> watched = const {}}) => _Catalog([
        for (var i = 1; i <= count; i++)
          _episode(100 + i, number: i, watched: watched.contains(100 + i)),
      ]);

  test('remplit la réserve jusqu’au compte demandé', () async {
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(10),
      library: library,
      preferences: preferences,
    );

    // Un seul épisode sur l'appareil, quatre demandés : il en manque trois.
    expect(await planner.topUp(showId), 3);
    expect(library.enqueued, [102, 103, 104]);
  });

  test('ne fait rien tant que la réserve est pleine', () async {
    final library = _Library([
      for (var id = 101; id <= 104; id++) _onDevice(id),
    ]);
    final catalog = catalogOf(10);
    final planner = AutoDownloadPlanner(
      catalog: catalog,
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 0);
    expect(library.enqueued, isEmpty);
    // Et surtout : rien n'a été demandé au serveur. C'est ce qui permet de
    // rejouer le plan à chaque notification du magasin sans le marteler.
    expect(catalog.nextCalls, 0);
  });

  test('un épisode regardé libère une place, qui se remplit', () async {
    // Cinq téléchargés, trois regardés : il en reste deux d'avance, donc deux
    // à rapatrier pour revenir à quatre. C'est l'exemple du trajet du matin.
    final library = _Library([
      for (var id = 101; id <= 105; id++) _onDevice(id, watched: id <= 103),
    ]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(10),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 2);
    expect(library.enqueued, [106, 107]);
  });

  test('un transfert en cours compte déjà comme de l’avance', () async {
    final library = _Library([
      _onDevice(101),
      _onDevice(102, status: DownloadStatus.downloading),
      _onDevice(103, status: DownloadStatus.queued),
    ]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(10),
      library: library,
      preferences: preferences,
    );

    // Trois sont là ou en route : un seul manque, pas trois.
    expect(await planner.topUp(showId), 1);
    expect(library.enqueued, [104]);
  });

  test('un épisode en échec ne compte pas comme de l’avance', () async {
    final library = _Library([
      _onDevice(101),
      _onDevice(102, status: DownloadStatus.failed),
    ]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(10),
      library: library,
      preferences: preferences,
    );

    // 101 seul tient lieu de réserve ; 102 est déjà connu, donc enjambé.
    expect(await planner.topUp(showId), 3);
    expect(library.enqueued, [103, 104, 105]);
  });

  test('s’arrête à la fin de la série', () async {
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(3),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 2);
    expect(library.enqueued, [102, 103]);
  });

  test('n’ouvre pas une série dont rien n’est téléchargé', () async {
    final library = _Library(const []);
    final catalog = catalogOf(10);
    final planner = AutoDownloadPlanner(
      catalog: catalog,
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 0);
    expect(catalog.nextCalls, 0, reason: 'le premier épisode reste un geste');
  });

  test('désactivé, rien ne descend', () async {
    await preferences.setMode(AutoDownloadMode.off);
    final library = _Library([_onDevice(101)]);
    final catalog = catalogOf(10);
    final planner = AutoDownloadPlanner(
      catalog: catalog,
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 0);
    expect(catalog.nextCalls, 0);
  });

  test('le compte d’avance est celui qui a été réglé', () async {
    await preferences.setKeepAhead(2);
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(10),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 1);
    expect(library.enqueued, [102]);
  });

  test('toute la série, sauf ce qui a déjà été vu', () async {
    await preferences.setMode(AutoDownloadMode.wholeShow);
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      catalog: catalogOf(6, watched: {103, 104}),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 3);
    expect(library.enqueued, [102, 105, 106]);
  });

  test('un serveur qui boucle sur lui-même n’enferme pas la file', () async {
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      // Le « suivant » de tout est 102, y compris celui de 102.
      catalog: _LoopingCatalog(_episode(102, number: 2)),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 1);
    expect(library.enqueued, [102]);
  });

  test('un épisode indisponible sur le serveur est enjambé', () async {
    final library = _Library([_onDevice(101)]);
    final planner = AutoDownloadPlanner(
      catalog: _Catalog([
        _episode(102, number: 2, available: false),
        _episode(103, number: 3),
        _episode(104, number: 4),
        _episode(105, number: 5),
      ]),
      library: library,
      preferences: preferences,
    );

    expect(await planner.topUp(showId), 3);
    expect(library.enqueued, [103, 104, 105]);
  });
}

HomeMediaItem _episode(
  int id, {
  required int number,
  bool watched = false,
  bool available = true,
}) {
  return HomeMediaItem(
    media: Media(
      id: id,
      type: MediaType.episode,
      title: 'Épisode $number',
      duration: 2400,
      seasonNumber: 1,
      episodeNumber: number,
      isAvailable: available,
      createdAt: DateTime(2026),
    ),
    currentPositionSeconds: 0,
    duration: 2400,
    isFinished: watched,
    showId: 7,
    showTitle: 'Ma série',
  );
}

OfflineDownload _onDevice(
  int id, {
  bool watched = false,
  DownloadStatus status = DownloadStatus.completed,
}) {
  return OfflineDownload(
    mediaId: id,
    type: MediaType.episode,
    title: 'Épisode ${id - 100}',
    fileName: 'video.mkv',
    addedAt: DateTime(2026),
    showId: 7,
    showTitle: 'Ma série',
    seasonNumber: 1,
    episodeNumber: id - 100,
    status: status,
    isFinished: watched,
  );
}

/// Une série linéaire : chaque épisode renvoie au suivant de la liste.
class _Catalog implements AutoDownloadCatalog {
  _Catalog(this.episodes);

  final List<HomeMediaItem> episodes;
  int nextCalls = 0;

  @override
  Future<HomeMediaItem?> nextEpisodeAfter(int episodeId) async {
    nextCalls++;
    final index = episodes.indexWhere((e) => e.media.id == episodeId);
    // Un épisode que le catalogue ne connaît pas (le point de départ posé par
    // l'appareil) : on repart du début de la liste.
    final from = index < 0 ? -1 : index;
    return from + 1 < episodes.length ? episodes[from + 1] : null;
  }

  @override
  Future<List<HomeMediaItem>> allEpisodesOf(int showId) async => episodes;
}

/// Un serveur qui répond toujours le même épisode.
class _LoopingCatalog implements AutoDownloadCatalog {
  _LoopingCatalog(this.always);

  final HomeMediaItem always;

  @override
  Future<HomeMediaItem?> nextEpisodeAfter(int episodeId) async => always;

  @override
  Future<List<HomeMediaItem>> allEpisodesOf(int showId) async => [always];
}

class _Library implements AutoDownloadLibrary {
  _Library(this.entries);

  final List<OfflineDownload> entries;
  final List<int> enqueued = [];

  @override
  Set<int> get showIds => {7};

  @override
  List<OfflineDownload> entriesForShow(int showId) => entries;

  @override
  Future<int> enqueue(
    List<HomeMediaItem> episodes, {
    required int showId,
    String? showTitle,
    String? showPosterUrl,
  }) async {
    enqueued.addAll(episodes.map((e) => e.media.id));
    return episodes.length;
  }
}
