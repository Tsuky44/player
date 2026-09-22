import 'dart:async';

import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/download_manager.dart';

class LibraryProvider extends ChangeNotifier {
  final ApiClient apiClient;

  List<HomeMediaItem> _movies = [];
  List<Media> _shows = [];
  List<Media> _seasons = [];
  List<HomeMediaItem> _episodes = [];

  bool _isLoadingMovies = false;
  bool _isLoadingShows = false;
  bool _isLoadingSeasons = false;
  bool _isLoadingEpisodes = false;

  String? _errorMessage;
  int _moviesRequest = 0;
  int _showsRequest = 0;
  int _seasonsRequest = 0;
  int _episodesRequest = 0;

  /// Per-show memory of what the show page last displayed, so a return visit
  /// paints at once and revalidates underneath. Cleared on a server change.
  final Map<int, List<Media>> _seasonsByShow = {};
  final Map<String, List<HomeMediaItem>> _episodesBySeason = {};
  final Map<int, ShowResumeResponse> _resumeByShow = {};

  /// The show [_seasons] belongs to.
  int? _seasonsShowId;

  LibraryProvider(this.apiClient);

  List<HomeMediaItem> get movies => _movies;
  List<Media> get shows => _shows;
  List<Media> get seasons => _seasons;
  List<HomeMediaItem> get episodes => _episodes;

  bool get isLoadingMovies => _isLoadingMovies;
  bool get isLoadingShows => _isLoadingShows;
  bool get isLoadingSeasons => _isLoadingSeasons;
  bool get isLoadingEpisodes => _isLoadingEpisodes;

  String? get errorMessage => _errorMessage;

  /// Vide le catalogue du serveur précédent. Voir [HomeProvider.reset].
  void reset() {
    _moviesRequest++;
    _showsRequest++;
    _seasonsRequest++;
    _episodesRequest++;
    _movies = [];
    _shows = [];
    _seasons = [];
    _episodes = [];
    _seasonsByShow.clear();
    _episodesBySeason.clear();
    _resumeByShow.clear();
    _seasonsShowId = null;
    _isLoadingMovies = false;
    _isLoadingShows = false;
    _isLoadingSeasons = false;
    _isLoadingEpisodes = false;
    _errorMessage = null;
    // The shell keeps its tabs mounted: initState will not run again.
    unawaited(loadMovies());
    unawaited(loadShows());
  }

  @override
  void dispose() {
    _moviesRequest++;
    _showsRequest++;
    _seasonsRequest++;
    _episodesRequest++;
    super.dispose();
  }

  Future<void> ensureCatalogLoaded() async {
    if (_movies.isEmpty && !_isLoadingMovies) {
      await loadMovies();
    }
    if (_shows.isEmpty && !_isLoadingShows) {
      await loadShows();
    }
  }

  List<Media> searchCatalog(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final results = <Media>[];
    for (final item in _movies) {
      if (item.media.title.toLowerCase().contains(q)) {
        results.add(item.media);
      }
    }
    for (final show in _shows) {
      if (show.title.toLowerCase().contains(q)) {
        results.add(show);
      }
    }

    results.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return results;
  }

  HomeMediaItem? movieItemFor(int mediaId) {
    for (final item in _movies) {
      if (item.media.id == mediaId) return item;
    }
    return null;
  }

  double? movieProgressFor(int mediaId) {
    final item = movieItemFor(mediaId);
    if (item == null || item.isFinished) return null;
    return item.percentWatched;
  }

  Media resolveCanonicalShow(Media show) {
    if (_shows.isEmpty) return show;
    final byId = _shows.where((s) => s.id == show.id).toList();
    if (byId.isNotEmpty) return byId.first;

    if (show.tmdbId != null && show.tmdbId! > 0) {
      for (final s in _shows) {
        if (s.tmdbId == show.tmdbId) return s;
      }
    }

    final key = show.title.trim().toLowerCase();
    for (final s in _shows) {
      if (s.title.trim().toLowerCase() == key) return s;
    }
    return show;
  }

  // Load movies list
  Future<void> loadMovies({bool silent = false}) async {
    final request = ++_moviesRequest;
    if (!silent) {
      _isLoadingMovies = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      final result = await apiClient.getMovies();
      if (request != _moviesRequest) return;
      _movies = result;
    } catch (e) {
      if (request != _moviesRequest) return;
      _errorMessage = "Erreur lors du chargement des films : ${e.toString()}";
    } finally {
      if (request == _moviesRequest) {
        _isLoadingMovies = false;
        notifyListeners();
      }
    }
  }

  // Load TV shows list
  Future<void> loadShows({bool silent = false}) async {
    final request = ++_showsRequest;
    if (!silent) {
      _isLoadingShows = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      final result = await apiClient.getShows();
      if (request != _showsRequest) return;
      _shows = result;
    } catch (e) {
      if (request != _showsRequest) return;
      _errorMessage = "Erreur lors du chargement des séries : ${e.toString()}";
    } finally {
      if (request == _showsRequest) {
        _isLoadingShows = false;
        notifyListeners();
      }
    }
  }

  /// Shows the seasons/episodes remembered for [showId] straight away, without
  /// a network call and **without notifying** — it is meant for a detail
  /// page's `initState`, which runs mid-build, so that its first frame is
  /// already this show instead of a spinner (or the previous show's list).
  /// [loadSeasons] / [loadEpisodes] revalidate right after.
  ///
  /// Returns false when nothing is remembered for this show.
  bool adoptCachedShow(int showId, {Media? season}) {
    final seasons = _seasonsByShow[showId];
    final episodes =
        season == null ? null : _episodesBySeason[_seasonKey(showId, season)];
    _seasonsRequest++;
    _episodesRequest++;
    // What is not remembered reads as loading, not as empty: the page's first
    // frame must not say "no episodes" for a show that has some.
    _isLoadingSeasons = seasons == null;
    _isLoadingEpisodes = season != null && episodes == null;
    _seasonsShowId = showId;
    _seasons = seasons ?? [];
    _episodes = episodes ?? [];
    return seasons != null;
  }

  List<Media>? cachedSeasons(int showId) => _seasonsByShow[showId];

  /// Where playback of [showId] resumed last time we asked, if we have.
  ShowResumeResponse? cachedResume(int showId) => _resumeByShow[showId];

  /// Asks the server where to resume [showId] and remembers the answer.
  /// Null on failure — callers keep whatever they were showing.
  Future<ShowResumeResponse?> loadResume(int showId) async {
    try {
      final resume = await apiClient.getShowResumeEpisode(showId);
      _resumeByShow[showId] = resume;
      return resume;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the seasons and resume point of [showId] into the cache without
  /// touching what is on screen — the hover/focus head start of a show page.
  Future<void> prefetchShow(int showId) async {
    if (showId <= 0) return;
    await Future.wait([
      if (!_seasonsByShow.containsKey(showId))
        apiClient
            .getShowSeasons(showId)
            .then((seasons) => _seasonsByShow[showId] = seasons)
            .catchError((_) => const <Media>[]),
      if (!_resumeByShow.containsKey(showId)) loadResume(showId),
    ]);
  }

  static String _seasonKey(int showId, Media season) =>
      '$showId:${season.id}:${season.effectiveSeasonNumber ?? season.seasonNumber}';

  // Load seasons for a TV Show. A show seen before this session is painted
  // from memory at once and refreshed underneath; only a first visit shows a
  // spinner.
  Future<void> loadSeasons(int showId) async {
    final request = ++_seasonsRequest;
    final cached = _seasonsByShow[showId];
    _seasonsShowId = showId;
    _isLoadingSeasons = cached == null;
    _seasons = cached ?? [];
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await apiClient.getShowSeasons(showId);
      if (request != _seasonsRequest) return;
      _seasons = result;
      _seasonsByShow[showId] = result;
    } catch (e) {
      if (request != _seasonsRequest) return;
      _errorMessage = "Erreur lors du chargement des saisons : ${e.toString()}";
    } finally {
      if (request == _seasonsRequest) {
        _isLoadingSeasons = false;
        notifyListeners();
      }
    }
  }

  // Load episodes of a season (local row or TMDB-only virtual season).
  Future<void> loadEpisodes(
      {required int showId, required Media season}) async {
    final request = ++_episodesRequest;
    final key = _seasonKey(showId, season);
    final cached = _episodesBySeason[key];
    _isLoadingEpisodes = cached == null;
    _episodes = cached ?? [];
    _errorMessage = null;
    notifyListeners();

    try {
      List<HomeMediaItem> result;
      if (season.id > 0) {
        result = await apiClient.getSeasonEpisodes(season.id);
      } else {
        final seasonNum = season.effectiveSeasonNumber ?? season.seasonNumber;
        if (seasonNum == null || seasonNum <= 0) {
          result = [];
        } else {
          result = await apiClient.getShowSeasonEpisodes(showId, seasonNum);
        }
      }
      if (request != _episodesRequest) return;
      _episodes = result;
      _episodesBySeason[key] = result;
    } catch (e) {
      if (request != _episodesRequest) return;
      _errorMessage =
          "Erreur lors du chargement des épisodes : ${e.toString()}";
    } finally {
      if (request == _episodesRequest) {
        _isLoadingEpisodes = false;
        notifyListeners();
      }
    }
  }

  /// Sends a MediaHub request for seasons missing from the server.
  ///
  /// On success the seasons flip to "requested" locally instead of being
  /// refetched: MediaHub takes a moment to expose a fresh request, and a refetch
  /// could hand back "requestable" right after the user asked for it.
  Future<void> requestSeasons({
    required Media show,
    required List<int> seasonNumbers,
  }) async {
    final tmdbId = show.tmdbId;
    if (tmdbId == null || tmdbId <= 0 || seasonNumbers.isEmpty) return;

    await apiClient.requestTmdbMedia(
      tmdbId: tmdbId,
      mediaType: 'tv',
      title: show.title,
      posterPath: _tmdbPosterPath(show.posterUrl),
      seasons: seasonNumbers,
    );

    final requested = seasonNumbers.toSet();
    _seasons = [
      for (final season in _seasons)
        if (!season.isAvailable &&
            season.effectiveSeasonNumber != null &&
            requested.contains(season.effectiveSeasonNumber))
          season.copyWith(requestStatus: 'pending', canRequest: false)
        else
          season,
    ];
    final showId = _seasonsShowId;
    if (showId != null) _seasonsByShow[showId] = _seasons;
    notifyListeners();
  }

  /// MediaHub stores TMDB poster *paths* ("/abc.jpg"), while the library holds
  /// full image URLs. Anything else is dropped rather than sent as-is.
  static String? _tmdbPosterPath(String? posterUrl) {
    if (posterUrl == null || posterUrl.isEmpty) return null;
    if (posterUrl.startsWith('/')) return posterUrl;
    final marker = RegExp(r'image\.tmdb\.org/t/p/[^/]+(/.+)$');
    return marker.firstMatch(posterUrl)?.group(1);
  }

  /// Recharge le catalogue sans vider l'écran : les pastilles « vu / en cours »
  /// viennent du serveur, et une série finie doit se marquer au retour du
  /// lecteur, pas au prochain lancement de l'application.
  Future<void> refreshCatalogSilently() async {
    await Future.wait([
      loadMovies(silent: true),
      loadShows(silent: true),
    ]);
  }

  Future<bool> setMediaWatched(int mediaId, bool watched) async {
    final result = await apiClient.setMediaWatched(mediaId, watched);
    final isFinished = result['is_finished'] as bool? ?? watched;
    final position = result['current_position_seconds'] as int? ?? 0;
    _patchLocalProgress(mediaId,
        isFinished: isFinished, positionSeconds: position);
    // Le manifeste hors ligne suit le même verdict. Sans ça, un épisode coché
    // « vu » depuis la bibliothèque resterait « à voir » dans l'écran des
    // téléchargements — et échapperait au ménage des médias vus.
    unawaited(DownloadManager.instance.recordProgress(
      mediaId: mediaId,
      positionSeconds: position,
      durationSeconds: 0,
      isFinished: isFinished,
      syncedWithServer: true,
    ));
    notifyListeners();
    return isFinished;
  }

  /// Marque une saison entière vue ou non vue en une requête.
  ///
  /// Renvoie le nombre d'épisodes que le serveur a effectivement changés — ce
  /// que dit le message de confirmation. Les positions partielles des épisodes
  /// concernés sont perdues : « j'ai fini cette saison » veut dire que le
  /// milieu de l'épisode 5 n'a plus à être retrouvé.
  Future<int> setMediasWatched(List<int> mediaIds, bool watched) async {
    if (mediaIds.isEmpty) return 0;
    final results = await apiClient.setMediasWatched(mediaIds, watched);
    results.forEach((mediaId, payload) {
      final isFinished = payload['is_finished'] as bool? ?? watched;
      final position = payload['current_position_seconds'] as int? ?? 0;
      _patchLocalProgress(mediaId,
          isFinished: isFinished, positionSeconds: position);
      // Même verdict pour le manifeste hors ligne que pour un épisode coché
      // seul : voir [setMediaWatched].
      unawaited(DownloadManager.instance.recordProgress(
        mediaId: mediaId,
        positionSeconds: position,
        durationSeconds: 0,
        isFinished: isFinished,
        syncedWithServer: true,
      ));
    });
    notifyListeners();
    return results.length;
  }

  void _patchLocalProgress(
    int mediaId, {
    required bool isFinished,
    required int positionSeconds,
  }) {
    _movies = [
      for (final item in _movies)
        if (item.media.id == mediaId)
          item.copyWith(
            isFinished: isFinished,
            currentPositionSeconds: positionSeconds,
          )
        else
          item,
    ];
    List<HomeMediaItem> patch(List<HomeMediaItem> items) => [
          for (final item in items)
            if (item.media.id == mediaId)
              item.copyWith(
                isFinished: isFinished,
                currentPositionSeconds: positionSeconds,
              )
            else
              item,
        ];
    _episodes = patch(_episodes);
    // The remembered seasons follow, or reopening the show would first paint
    // the episode as it was before the tick.
    for (final key in _episodesBySeason.keys.toList()) {
      final cached = _episodesBySeason[key]!;
      if (cached.any((item) => item.media.id == mediaId)) {
        _episodesBySeason[key] = patch(cached);
      }
    }
  }
}
