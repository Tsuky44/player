import '../../models/models.dart';
import '../../models/offline_download.dart';

/// Ce que le bouton de saison sait d'une saison : ce qui est là, ce qui
/// descend, et ce qu'un appui ajouterait.
///
/// Séparé du widget pour être éprouvé sans gestionnaire de téléchargements :
/// le compteur affiché pendant le transfert s'est déjà trompé de dénominateur
/// (« 0/20 » pour quatre non vus lancés sur vingt épisodes).
class SeasonDownloadPlan {
  /// Les épisodes que le serveur a vraiment, dans l'ordre de la saison.
  final List<HomeMediaItem> downloadable;

  /// Ceux qui ne sont pas vus, commencés compris.
  final List<HomeMediaItem> unwatched;

  /// Épisodes complets sur l'appareil.
  final int done;

  /// Épisodes en file ou en cours de transfert.
  final int running;

  /// Épisodes ni complets ni en cours — absents, en pause ou en échec.
  final int missing;

  /// Épisodes que l'utilisateur a demandés, quel que soit leur état : le
  /// dénominateur du compteur pendant le transfert.
  final int requested;

  /// Non vus ni complets ni en cours.
  final int unwatchedMissing;

  const SeasonDownloadPlan._({
    required this.downloadable,
    required this.unwatched,
    required this.done,
    required this.running,
    required this.missing,
    required this.requested,
    required this.unwatchedMissing,
  });

  factory SeasonDownloadPlan.of(
    List<HomeMediaItem> episodes,
    OfflineDownload? Function(int mediaId) entryFor,
  ) {
    final downloadable = [
      for (final episode in episodes)
        if (episode.isAvailable && episode.media.type == MediaType.episode)
          episode,
    ];
    var done = 0, running = 0, requested = 0, unwatchedMissing = 0;
    final unwatched = <HomeMediaItem>[];
    for (final episode in downloadable) {
      final entry = entryFor(episode.media.id);
      if (entry != null) requested++;
      final completed = entry?.isCompleted ?? false;
      final active = entry?.isActive ?? false;
      if (completed) done++;
      if (active) running++;
      if (!episode.isFinished) {
        unwatched.add(episode);
        if (!completed && !active) unwatchedMissing++;
      }
    }
    return SeasonDownloadPlan._(
      downloadable: downloadable,
      unwatched: unwatched,
      done: done,
      running: running,
      missing: downloadable.length - done - running,
      requested: requested,
      unwatchedMissing: unwatchedMissing,
    );
  }

  bool get isEmpty => downloadable.isEmpty;

  /// Tout est sur l'appareil et rien ne descend.
  bool get isComplete => missing == 0 && running == 0;

  /// Au moins un épisode vu : ce qu'on emporte d'abord, c'est la suite.
  bool get partlyWatched => unwatched.length < downloadable.length;

  /// Ce qu'un appui mettrait en file, ou null s'il n'y a rien à ajouter.
  ///
  /// Sur une saison entamée, uniquement les non vus : les épisodes déjà vus ne
  /// se proposent (par « Compléter ») qu'une fois tous les autres là, et
  /// jamais pendant qu'un lot de non vus descend.
  List<HomeMediaItem>? get nextBatch {
    if (partlyWatched && (unwatchedMissing > 0 || running > 0)) {
      return unwatchedMissing > 0 ? unwatched : null;
    }
    return missing > 0 ? downloadable : null;
  }

  /// Vrai quand [nextBatch] ne vise que les non vus.
  bool get nextBatchIsUnwatched =>
      partlyWatched && unwatchedMissing > 0;
}
