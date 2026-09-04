import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/download_manager.dart';

class HomeProvider extends ChangeNotifier {
  static const double _minContinueWatchingPercent = 10.0;

  final ApiClient apiClient;

  HomeResponse? _homeData;
  bool _isLoading = false;
  bool _isScanning = false;
  bool _isBackfillingMetadata = false;
  bool _isRedetectingAll = false;
  RedetectAllProgress _redetectAllProgress = RedetectAllProgress();
  bool _isExtractingSubtitles = false;
  SubtitleExtractionStats _subtitleStats = SubtitleExtractionStats();
  String? _errorMessage;
  String? _completionMessage;
  Timer? _statusPollTimer;

  HomeProvider(this.apiClient);

  HomeResponse? get homeData => _homeData;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  bool get isBackfillingMetadata => _isBackfillingMetadata;
  bool get isRedetectingAll => _isRedetectingAll;
  RedetectAllProgress get redetectAllProgress => _redetectAllProgress;
  bool get isExtractingSubtitles => _isExtractingSubtitles;
  SubtitleExtractionStats get subtitleStats => _subtitleStats;
  String? get errorMessage => _errorMessage;

  /// One-shot message shown by the UI after a background job finishes.
  String? consumeCompletionMessage() {
    final msg = _completionMessage;
    _completionMessage = null;
    return msg;
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  Future<void> loadHome({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      _homeData = await apiClient.getHome();
      _errorMessage = null;

      final status = await apiClient.getIndexerStatus();
      _applyIndexerStatus(status);
      if (status.isBusy) {
        _startStatusPolling();
      }
    } catch (e) {
      _errorMessage = "Impossible de charger la page d'accueil : ${e.toString()}";
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  bool _meetsContinueWatchingThreshold({
    required int positionSeconds,
    required int durationSeconds,
  }) {
    if (positionSeconds <= 0) return false;
    if (durationSeconds <= 0) return true;
    return (positionSeconds / durationSeconds) * 100 >= _minContinueWatchingPercent;
  }

  /// Instantly updates the continue-watching row after leaving the player.
  void updateContinueWatchingProgress({
    required int mediaId,
    required int positionSeconds,
    required int durationSeconds,
    required bool isFinished,
    HomeMediaItem? sourceItem,
  }) {
    if (_homeData == null) return;
    if (positionSeconds <= 0 && !isFinished) return;

    final now = DateTime.now();
    var list = List<HomeMediaItem>.from(_homeData!.continueWatching);

    if (sourceItem?.media.type == MediaType.episode) {
      final showKey = sourceItem!.displayTitle.toLowerCase();
      list.removeWhere(
        (item) =>
            item.media.id != mediaId &&
            item.media.type == MediaType.episode &&
            item.displayTitle.toLowerCase() == showKey,
      );
    }

    final index = list.indexWhere((item) => item.media.id == mediaId);
    final effectiveDuration = durationSeconds > 0
        ? durationSeconds
        : (sourceItem?.duration ?? 0);

    if (!isFinished &&
        !_meetsContinueWatchingThreshold(
          positionSeconds: positionSeconds,
          durationSeconds: effectiveDuration,
        )) {
      if (index >= 0) {
        list.removeAt(index);
        _homeData = HomeResponse(
          continueWatching: list,
          recentMovies: _homeData!.recentMovies,
          recentShows: _homeData!.recentShows,
          discoveryMovies: _homeData!.discoveryMovies,
          discoveryShows: _homeData!.discoveryShows,
        );
        notifyListeners();
      }
      return;
    }

    if (isFinished) {
      // Séries : le serveur renverra l'épisode suivant après refresh.
      if (sourceItem?.media.type == MediaType.episode &&
          sourceItem!.showId != null &&
          sourceItem.showId! > 0) {
        return;
      }
      if (index >= 0) list.removeAt(index);
    } else if (index >= 0) {
      final current = list.removeAt(index);
      list.insert(
        0,
        current.copyWith(
          currentPositionSeconds: positionSeconds,
          duration: durationSeconds > 0 ? durationSeconds : current.duration,
          isFinished: false,
          updatedAt: now,
        ),
      );
    } else if (sourceItem != null) {
      list.insert(
        0,
        sourceItem.copyWith(
          currentPositionSeconds: positionSeconds,
          duration: durationSeconds > 0 ? durationSeconds : sourceItem.duration,
          isFinished: false,
          updatedAt: now,
        ),
      );
    } else {
      return;
    }

    _homeData = HomeResponse(
      continueWatching: list,
      recentMovies: _homeData!.recentMovies,
      recentShows: _homeData!.recentShows,
      discoveryMovies: _homeData!.discoveryMovies,
      discoveryShows: _homeData!.discoveryShows,
    );
    notifyListeners();
  }

  void _removeContinueWatchingItem(HomeMediaItem item) {
    if (_homeData == null) return;
    final list = List<HomeMediaItem>.from(_homeData!.continueWatching);
    list.removeWhere((entry) => _isSameContinueWatchingEntry(entry, item));
    _homeData = HomeResponse(
      continueWatching: list,
      recentMovies: _homeData!.recentMovies,
      recentShows: _homeData!.recentShows,
      discoveryMovies: _homeData!.discoveryMovies,
      discoveryShows: _homeData!.discoveryShows,
    );
    notifyListeners();
  }

  bool _isSameContinueWatchingEntry(HomeMediaItem a, HomeMediaItem b) {
    if (a.media.type == MediaType.episode &&
        b.media.type == MediaType.episode &&
        a.showId != null &&
        b.showId != null &&
        a.showId! > 0 &&
        b.showId! > 0) {
      return a.showId == b.showId;
    }
    return a.media.id == b.media.id;
  }

  Future<void> hideContinueWatchingItem(HomeMediaItem item) async {
    if (item.media.type == MediaType.movie) {
      await apiClient.hideFromContinueWatching(movieId: item.media.id);
    } else if (item.showId != null && item.showId! > 0) {
      await apiClient.hideFromContinueWatching(showId: item.showId);
    } else {
      return;
    }
    _removeContinueWatchingItem(item);
  }

  Future<void> markContinueWatchingAsWatched(HomeMediaItem item) async {
    final result = await apiClient.setMediaWatched(item.media.id, true);
    // Le manifeste hors ligne suit : un épisode marqué vu ici doit apparaître
    // vu dans l'écran des téléchargements, et entrer dans le ménage des vus.
    unawaited(DownloadManager.instance.recordProgress(
      mediaId: item.media.id,
      positionSeconds: result['current_position_seconds'] as int? ?? 0,
      durationSeconds: 0,
      isFinished: result['is_finished'] as bool? ?? true,
      syncedWithServer: true,
    ));
    await loadHome(silent: true);
  }

  Future<void> triggerLibraryScan() async {
    if (_isScanning) return;

    try {
      await apiClient.triggerScan();
      _isScanning = true;
      notifyListeners();
      _startStatusPolling();
    } catch (e) {
      _errorMessage = "Erreur lors du lancement du scan : ${e.toString()}";
      notifyListeners();
    }
  }

  Future<void> triggerSubtitleExtract() async {
    if (_isExtractingSubtitles) return;

    try {
      await apiClient.triggerSubtitleExtract();
      _isExtractingSubtitles = true;
      notifyListeners();
      _startStatusPolling();
    } catch (e) {
      _errorMessage = "Erreur lors de l'extraction des sous-titres : ${e.toString()}";
      notifyListeners();
      rethrow;
    }
  }

  Future<void> triggerMetadataBackfill() async {
    if (_isBackfillingMetadata) return;

    try {
      await apiClient.triggerMetadataBackfill();
      _isBackfillingMetadata = true;
      notifyListeners();
      _startStatusPolling();
    } catch (e) {
      _errorMessage = "Erreur lors de la mise à jour des affiches : ${e.toString()}";
      notifyListeners();
    }
  }

  Future<void> triggerRedetectAllMatches() async {
    if (_isRedetectingAll) return;

    try {
      await apiClient.triggerRedetectAllMatches();
      _isRedetectingAll = true;
      notifyListeners();
      _startStatusPolling();
    } catch (e) {
      _errorMessage =
          "Erreur lors de la re-détection des matchs : ${e.toString()}";
      notifyListeners();
      rethrow;
    }
  }

  void _applyIndexerStatus(IndexerStatus status) {
    _isScanning = status.isScanning;
    _isBackfillingMetadata = status.isBackfillingMetadata;
    _isRedetectingAll = status.isRedetectingAll;
    _redetectAllProgress = status.redetectAll;
    _isExtractingSubtitles = status.isExtractingSubtitles;
    _subtitleStats = status.subtitleExtraction;
  }

  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    var wasScanning = _isScanning;
    var wasBackfilling = _isBackfillingMetadata;
    var wasRedetecting = _isRedetectingAll;
    var wasExtracting = _isExtractingSubtitles;

    _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final status = await apiClient.getIndexerStatus();
        final scanJustFinished = wasScanning && !status.isScanning;
        final backfillJustFinished =
            wasBackfilling && !status.isBackfillingMetadata;
        final redetectJustFinished =
            wasRedetecting && !status.isRedetectingAll;
        final extractJustFinished = wasExtracting && !status.isExtractingSubtitles;

        _applyIndexerStatus(status);

        if (extractJustFinished) {
          final s = status.subtitleExtraction;
          _completionMessage =
              "Sous-titres extraits : ${s.succeeded}/${s.total} médias (${s.tracks} pistes)";
        } else if (backfillJustFinished) {
          _completionMessage = "Affiches mises à jour depuis TMDB";
        } else if (redetectJustFinished) {
          final r = status.redetectAll;
          _completionMessage =
              "Re-détection terminée : ${r.updated} mis à jour, ${r.skipped} sans changement (${r.total} titres)";
        }

        notifyListeners();

        wasScanning = status.isScanning;
        wasBackfilling = status.isBackfillingMetadata;
        wasRedetecting = status.isRedetectingAll;
        wasExtracting = status.isExtractingSubtitles;

        if (!status.isBusy) {
          timer.cancel();
          _statusPollTimer = null;
          if (scanJustFinished || backfillJustFinished || redetectJustFinished) {
            await loadHome(silent: true);
          }
        }
      } catch (_) {
        _isScanning = false;
        _isBackfillingMetadata = false;
        _isRedetectingAll = false;
        _isExtractingSubtitles = false;
        timer.cancel();
        _statusPollTimer = null;
        notifyListeners();
      }
    });
  }
}
