import 'media_share.dart';
import 'models.dart';
import '../l10n/tr.dart';

/// Où le visiteur d'un lien de saison ou de série en est, d'après ce que
/// l'appareil a retenu : le serveur ne garde la progression de personne sans
/// compte (ADR-0037 §8).
class SharedLinkProgress {
  const SharedLinkProgress({
    this.positions = const {},
    this.finished = const {},
    this.lastEpisodeId,
  });

  /// La position gardée de chaque épisode commencé, en secondes.
  final Map<int, int> positions;

  /// Les épisodes vus jusqu'au bout.
  final Set<int> finished;

  /// Le dernier épisode regardé : c'est de lui que part la reprise.
  final int? lastEpisodeId;
}

/// Le lien d'une saison ou d'une série, sous la forme que la fiche et le
/// lecteur d'un compte connaissent déjà : des saisons, des épisodes avec leur
/// avancement, l'épisode suivant, le point de reprise (ADR-0037 §10).
///
/// Tout vient de ce que le lien a décrit ([SharedMediaInfo]) et de ce que
/// l'appareil a retenu ([SharedLinkProgress]) : aucune requête.
class SharedShow {
  SharedShow(this.info, [this.progress = const SharedLinkProgress()]);

  final SharedMediaInfo info;
  final SharedLinkProgress progress;

  // Un épisode n'a pas de date d'ajout pour un visiteur ; le modèle en veut une.
  static final DateTime _noDate = DateTime.fromMillisecondsSinceEpoch(0);

  /// L'identifiant de la série sur le serveur du lien, ou 0 s'il ne l'a pas
  /// dit.
  int get showId => info.details?.id ?? 0;

  /// La série, telle que l'en-tête de la fiche l'attend avant sa fiche
  /// complète.
  late final Media show = Media(
    id: showId,
    type: MediaType.show,
    title: info.title,
    duration: 0,
    posterUrl: info.details?.posterUrl ?? info.posterUrl,
    overview: info.details?.overview,
    releaseDate: info.details?.releaseDate,
    createdAt: _noDate,
  );

  /// Un serveur plus ancien ne dit pas la saison d'un épisode : ses épisodes
  /// se rangent alors par numéro de saison, sous un identifiant négatif qui
  /// ne peut pas croiser celui d'une vraie saison.
  static int _seasonKey(SharedEpisode episode) =>
      episode.seasonId > 0 ? episode.seasonId : -(episode.seasonNumber + 1);

  /// Les saisons que le lien ouvre, dans l'ordre de diffusion.
  late final List<Media> seasons = () {
    final seen = <int>{};
    return [
      for (final episode in info.episodes)
        if (seen.add(_seasonKey(episode)))
          Media(
            id: _seasonKey(episode),
            type: MediaType.season,
            title: episode.seasonNumber > 0
                ? tr('Saison {0}', [episode.seasonNumber])
                : tr('Épisodes spéciaux'),
            duration: 0,
            parentId: showId,
            seasonNumber: episode.seasonNumber,
            createdAt: _noDate,
          ),
    ];
  }();

  /// Tous les épisodes du lien, dans l'ordre de diffusion.
  late final List<HomeMediaItem> episodes =
      List.unmodifiable(info.episodes.map(_item));

  HomeMediaItem _item(SharedEpisode episode) {
    final finished = progress.finished.contains(episode.id);
    return HomeMediaItem(
      media: Media(
        id: episode.id,
        type: MediaType.episode,
        title: episode.title.isNotEmpty
            ? episode.title
            : tr('Épisode {0}', [episode.episodeNumber]),
        duration: episode.duration,
        parentId: _seasonKey(episode),
        // Comme pour un compte : sans image propre, l'épisode montre l'affiche
        // de sa série.
        posterUrl: episode.stillUrl ?? info.posterUrl,
        overview: episode.overview,
        releaseDate: episode.releaseDate,
        seasonNumber: episode.seasonNumber,
        episodeNumber: episode.episodeNumber,
        createdAt: _noDate,
      ),
      currentPositionSeconds:
          finished ? 0 : progress.positions[episode.id] ?? 0,
      duration: episode.duration,
      isFinished: finished,
      introStart: episode.introStart,
      introEnd: episode.introEnd,
      outroStart: episode.outroStart,
      outroEnd: episode.outroEnd,
      showTitle: info.title,
      showPosterUrl: info.posterUrl,
      showId: showId,
    );
  }

  List<HomeMediaItem> episodesOf(int seasonId) =>
      [for (final e in episodes) if (e.media.parentId == seasonId) e];

  HomeMediaItem? episode(int id) {
    for (final e in episodes) {
      if (e.media.id == id) return e;
    }
    return null;
  }

  /// L'épisode qui suit [id] dans le lien, d'une saison à l'autre ; nul après
  /// le dernier, ou si [id] n'est pas de ce lien.
  HomeMediaItem? after(int id) {
    final index = episodes.indexWhere((e) => e.media.id == id);
    if (index < 0 || index + 1 >= episodes.length) return null;
    return episodes[index + 1];
  }

  /// L'épisode que le bouton principal lance, comme sur la fiche d'un compte :
  /// celui qu'on regardait s'il n'est pas fini, le suivant s'il l'est, le
  /// premier quand rien n'est commencé — ou quand tout est vu.
  late final HomeMediaItem? resumeEpisode = () {
    if (episodes.isEmpty) return null;
    final last = progress.lastEpisodeId;
    final current = last == null ? null : episode(last);
    if (current == null) return episodes.first;
    if (!current.isFinished) return current;
    return after(current.media.id) ?? episodes.first;
  }();

  /// Vrai quand [resumeEpisode] est entamé : le bouton dit « Reprendre ».
  bool get isResuming {
    final episode = resumeEpisode;
    return episode != null &&
        !episode.isFinished &&
        episode.currentPositionSeconds > 0;
  }
}
