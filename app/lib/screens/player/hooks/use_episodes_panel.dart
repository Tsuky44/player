import 'package:flutter/foundation.dart';

import '../../../models/models.dart';
import '../../../services/api_client.dart';

/// Le panneau des épisodes du lecteur, et l'épisode qui précède celui qui
/// joue.
///
/// Le serveur ne répond qu'à « qu'est-ce qui vient après » : l'épisode d'avant
/// se lit dans la liste de la saison, la même que celle du panneau.
class EpisodesPanelController extends ChangeNotifier {
  EpisodesPanelController({
    required this.api,
    required this.currentSeasonId,
    required this.currentShowId,
    required this.currentEpisodeId,
  });

  /// Null tant que le lecteur n'a pas épinglé son serveur.
  final ApiClient? Function() api;
  final int? currentSeasonId;
  final int? currentShowId;
  final int currentEpisodeId;

  bool isOpen = false;
  bool isLoading = false;
  List<Media> seasons = [];
  List<HomeMediaItem> episodes = [];
  int? selectedSeasonId;
  String showTitle = '';

  /// The episode before this one inside the same season, when there is one.
  HomeMediaItem? previousEpisode;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> open({required String showTitle}) async {
    isOpen = true;
    isLoading = true;
    this.showTitle = showTitle;
    selectedSeasonId = currentSeasonId;
    episodes = [];
    _notify();
    await _load();
  }

  /// Returns whether the panel was open.
  bool close() {
    if (!isOpen) return false;
    isOpen = false;
    _notify();
    return true;
  }

  Future<void> selectSeason(int seasonId) {
    isLoading = true;
    episodes = [];
    _notify();
    return _load(seasonId: seasonId);
  }

  Future<void> _load({int? seasonId}) async {
    final client = api();
    if (client == null) return;

    final targetSeasonId = seasonId ?? currentSeasonId;
    if (targetSeasonId == null || targetSeasonId <= 0) {
      isLoading = false;
      _notify();
      return;
    }

    try {
      if (seasons.isEmpty) {
        final showId = currentShowId;
        if (showId != null && showId > 0) {
          seasons = await client.getShowSeasons(showId);
        }
      }

      final loaded = await client.getSeasonEpisodes(targetSeasonId);
      if (_disposed) return;

      episodes = loaded;
      selectedSeasonId = targetSeasonId;
      if (loaded.isNotEmpty && loaded.first.showTitle?.isNotEmpty == true) {
        showTitle = loaded.first.showTitle!;
      }
      isLoading = false;
      _notify();
    } catch (error) {
      debugPrint('Player: episode panel failed to load: $error');
      isLoading = false;
      _notify();
    }
  }

  /// Resolves [previousEpisode] from the current season listing.
  ///
  /// Season-crossing is deliberately not attempted: going back would mean
  /// fetching the previous season's episodes to find its last one, and the
  /// episode panel already covers that case.
  Future<void> loadPreviousEpisode() async {
    final client = api();
    final seasonId = currentSeasonId;
    if (client == null || seasonId == null || seasonId <= 0) return;

    try {
      final listing = await client.getSeasonEpisodes(seasonId);
      if (_disposed) return;
      final idx = listing.indexWhere((e) => e.media.id == currentEpisodeId);
      if (idx <= 0) return;
      previousEpisode = listing[idx - 1];
      _notify();
    } catch (_) {
      // A missing back button is a smaller failure than a broken player.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
