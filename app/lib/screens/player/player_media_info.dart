import '../../models/models.dart';
import '../../utils/format.dart';
import '../../utils/release_tag.dart';

/// Ce que le lecteur sait du média qu'il ouvre, et les titres qu'il en tire.
///
/// Le lecteur reçoit un [Media] (une fiche, la liste d'une saison) ou un
/// [HomeMediaItem] (une rangée de l'accueil, qui en sait plus : la série,
/// les repères du générique, la progression). Les deux se lisent ici, une
/// seule fois.
class PlayerMediaInfo {
  PlayerMediaInfo(this.source, {this.seasonNumber})
      : assert(source is Media || source is HomeMediaItem);

  final Object source;

  /// La saison imposée par l'écran qui a ouvert le lecteur, s'il la connaît.
  final int? seasonNumber;

  HomeMediaItem? get item =>
      source is HomeMediaItem ? source as HomeMediaItem : null;

  Media get media => item?.media ?? source as Media;

  bool get isEpisode => media.type == MediaType.episode;
  int? get seasonId => media.parentId;
  int? get showId => item?.showId;

  /// The title shown in player overlays: show name and code on an episode.
  String get playerTitle =>
      playerMediaTitle(source, seasonNumber: seasonNumber);

  /// The show name on an episode, the film title on a movie.
  String get showTitle {
    final known = item;
    if (known != null) return known.displayTitle;
    final parts = playerTitle.split(' – ');
    return parts.isNotEmpty ? parts.first : playerTitle;
  }

  /// The episode's own title (TV) or the media title (movies) — as opposed
  /// to [showTitle], which is the show name. [playerTitle] combines show name
  /// + code and must not be used here or the code/title repeat.
  String get _episodeOrMovieTitle {
    final known = item;
    if (known != null && known.media.type == MediaType.episode) {
      return known.episodeTitle ?? known.media.title;
    }
    return showTitle;
  }

  /// Muted line above the title: `S1:E3 - …` on an episode, the release year
  /// on a movie.
  ///
  /// Without the release tag parsed from the filename. The chrome over the
  /// video names the episode; the quality/source belongs to the info panel,
  /// which is where someone goes looking for it.
  String? get overline {
    if (!isEpisode) return extractYear(media.releaseDate);
    return composeEpisodeInfoLine(
      seasonEpisodeCode: media.seasonEpisodeCode,
      title: _episodeOrMovieTitle,
    );
  }

  /// La fiche qui porte le logo-titre : celle du film, ou celle de la série
  /// pour un épisode. Null quand elle ne peut pas se déduire.
  int? get logoDetailsId {
    int? detailsId;
    if (media.type == MediaType.movie || media.type == MediaType.show) {
      detailsId = media.id;
    } else if (media.type == MediaType.episode) {
      // The logo belongs to the show, so an episode has to resolve its parent.
      // showId is only present when the player was opened from a home row;
      // parentId covers the episode-list route, which otherwise got no logo.
      detailsId = showId;
      if (detailsId == null || detailsId <= 0) detailsId = media.parentId;
    }
    if (detailsId == null || detailsId <= 0) return null;
    return detailsId;
  }

  /// La durée la plus sûre connue avant que le moteur n'ait la sienne.
  int get knownDurationSeconds => item?.effectiveDuration ?? media.duration;

  /// La saison à annoncer pour [next], l'épisode qu'on s'apprête à ouvrir.
  int? seasonNumberFor(Object next) {
    if (seasonNumber != null && seasonNumber! > 0) return seasonNumber;
    if (next is HomeMediaItem) return next.media.effectiveSeasonNumber;
    if (next is Media) return next.effectiveSeasonNumber;
    return null;
  }
}
