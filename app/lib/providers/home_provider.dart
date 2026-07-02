import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_client.dart';

class HomeProvider extends ChangeNotifier {
  final ApiClient apiClient;

  HomeResponse? _homeData;
  bool _isLoading = false;
  bool _isScanning = false;
  bool _isBackfillingMetadata = false;
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

    if (isFinished) {
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

  void _applyIndexerStatus(IndexerStatus status) {
    _isScanning = status.isScanning;
    _isBackfillingMetadata = status.isBackfillingMetadata;
    _isExtractingSubtitles = status.isExtractingSubtitles;
    _subtitleStats = status.subtitleExtraction;
  }

  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    var wasScanning = _isScanning;
    var wasBackfilling = _isBackfillingMetadata;
    var wasExtracting = _isExtractingSubtitles;

    _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final status = await apiClient.getIndexerStatus();
        final scanJustFinished = wasScanning && !status.isScanning;
        final backfillJustFinished = wasBackfilling && !status.isBackfillingMetadata;
        final extractJustFinished = wasExtracting && !status.isExtractingSubtitles;

        _applyIndexerStatus(status);

        if (extractJustFinished) {
          final s = status.subtitleExtraction;
          _completionMessage =
              "Sous-titres extraits : ${s.succeeded}/${s.total} médias (${s.tracks} pistes)";
        } else if (backfillJustFinished) {
          _completionMessage = "Affiches mises à jour depuis TMDB";
        }

        notifyListeners();

        wasScanning = status.isScanning;
        wasBackfilling = status.isBackfillingMetadata;
        wasExtracting = status.isExtractingSubtitles;

        if (!status.isBusy) {
          timer.cancel();
          _statusPollTimer = null;
          if (scanJustFinished || backfillJustFinished) {
            await loadHome(silent: true);
          }
        }
      } catch (_) {
        _isScanning = false;
        _isBackfillingMetadata = false;
        _isExtractingSubtitles = false;
        timer.cancel();
        _statusPollTimer = null;
        notifyListeners();
      }
    });
  }
}
