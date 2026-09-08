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

  // Clear sub-tier data (prevents old season/episode flash when clicking another show)
  void clearSeasonsAndEpisodes() {
    _seasonsRequest++;
    _episodesRequest++;
    _isLoadingSeasons = false;
    _isLoadingEpisodes = false;
    _seasons = [];
    _episodes = [];
    notifyListeners();
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
  Future<void> loadShows() async {
    final request = ++_showsRequest;
    _isLoadingShows = true;
    _errorMessage = null;
    notifyListeners();

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

  // Load seasons for a TV Show
  Future<void> loadSeasons(int showId) async {
    final request = ++_seasonsRequest;
    _isLoadingSeasons = true;
    _seasons = []; // Reset first
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await apiClient.getShowSeasons(showId);
      if (request != _seasonsRequest) return;
      _seasons = result;
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
    _isLoadingEpisodes = true;
    _episodes = [];
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
    _episodes = [
      for (final item in _episodes)
        if (item.media.id == mediaId)
          item.copyWith(
            isFinished: isFinished,
            currentPositionSeconds: positionSeconds,
          )
        else
          item,
    ];
  }
}
