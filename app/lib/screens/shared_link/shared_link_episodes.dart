import 'package:flutter/material.dart';

import '../../models/media_share.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/format.dart';

/// Les épisodes du lien d'une saison ou d'une série (ADR-0037 §8), parmi
/// lesquels le visiteur choisit celui qu'il regarde.
///
/// Passif : la page du lien ouvre l'épisode choisi. Les saisons ne sont
/// nommées que s'il y en a plusieurs.
class SharedLinkEpisodes extends StatelessWidget {
  const SharedLinkEpisodes({
    super.key,
    required this.episodes,
    required this.onPlay,
    this.openingId,
  });

  final List<SharedEpisode> episodes;

  /// Nul pendant qu'un épisode s'ouvre : un seul à la fois.
  final ValueChanged<SharedEpisode>? onPlay;

  /// L'épisode en train de s'ouvrir, qui montre l'attente.
  final int? openingId;

  @override
  Widget build(BuildContext context) {
    final severalSeasons =
        episodes.map((e) => e.seasonNumber).toSet().length > 1;
    int? season;
    final rows = <Widget>[];
    for (final episode in episodes) {
      if (severalSeasons && episode.seasonNumber != season) {
        season = episode.seasonNumber;
        rows.add(Padding(
          padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 16, bottom: 4),
          child: Text(
            season > 0 ? 'Saison $season' : 'Épisodes spéciaux',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppType.subhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ));
      }
      rows.add(_EpisodeRow(
        episode: episode,
        opening: openingId == episode.id,
        onPlay: onPlay == null ? null : () => onPlay!(episode),
      ));
    }
    // La carte de la page peint son fond par-dessus celui du Scaffold : sans
    // ce Material, l'encre des lignes resterait dessous, invisible.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.opening,
    required this.onPlay,
  });

  final SharedEpisode episode;
  final bool opening;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final number =
        episode.episodeNumber > 0 ? 'Épisode ${episode.episodeNumber}' : '';
    final title = episode.title.isEmpty
        ? (number.isEmpty ? 'Épisode' : number)
        : number.isEmpty
            ? episode.title
            : '${episode.episodeNumber}. ${episode.title}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      onTap: onPlay,
      leading: opening
          ? const SizedBox(
              width: 24,
              height: 24,
              child: Padding(
                padding: EdgeInsets.all(3),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const Icon(Icons.play_arrow_rounded),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: episode.duration > 0
          ? Text(
              formatDuration(episode.duration),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
              ),
            )
          : null,
    );
  }
}
