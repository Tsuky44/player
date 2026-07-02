import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';

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

  // Clear sub-tier data (prevents old season/episode flash when clicking another show)
  void clearSeasonsAndEpisodes() {
    _seasons = [];
    _episodes = [];
    notifyListeners();
  }

  // Load movies list
  Future<void> loadMovies() async {
    _isLoadingMovies = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _movies = await apiClient.getMovies();
    } catch (e) {
      _errorMessage = "Erreur lors du chargement des films : ${e.toString()}";
    } finally {
      _isLoadingMovies = false;
      notifyListeners();
    }
  }

  // Load TV shows list
  Future<void> loadShows() async {
    _isLoadingShows = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _shows = await apiClient.getShows();
    } catch (e) {
      _errorMessage = "Erreur lors du chargement des séries : ${e.toString()}";
    } finally {
      _isLoadingShows = false;
      notifyListeners();
    }
  }

  // Load seasons for a TV Show
  Future<void> loadSeasons(int showId) async {
    _isLoadingSeasons = true;
    _seasons = []; // Reset first
    _errorMessage = null;
    notifyListeners();

    try {
      _seasons = await apiClient.getShowSeasons(showId);
    } catch (e) {
      _errorMessage = "Erreur lors du chargement des saisons : ${e.toString()}";
    } finally {
      _isLoadingSeasons = false;
      notifyListeners();
    }
  }

  // Load episodes of a season
  Future<void> loadEpisodes(int seasonId) async {
    _isLoadingEpisodes = true;
    _episodes = []; // Reset first
    _errorMessage = null;
    notifyListeners();

    try {
      _episodes = await apiClient.getSeasonEpisodes(seasonId);
    } catch (e) {
      _errorMessage = "Erreur lors du chargement des épisodes : ${e.toString()}";
    } finally {
      _isLoadingEpisodes = false;
      notifyListeners();
    }
  }

  Future<bool> setMediaWatched(int mediaId, bool watched) async {
    final result = await apiClient.setMediaWatched(mediaId, watched);
    final isFinished = result['is_finished'] as bool? ?? watched;
    final position = result['current_position_seconds'] as int? ?? 0;
    _patchLocalProgress(mediaId, isFinished: isFinished, positionSeconds: position);
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
