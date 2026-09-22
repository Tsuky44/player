import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';

/// « J'ai fini cette saison », en un geste.
///
/// Le pendant de `SeasonDownloadButton` : rattraper une saison vue ailleurs
/// demandait vingt appuis sur vingt lignes, qui disent tous la même chose.
/// Seuls les épisodes que le serveur possède sont concernés — un épisode
/// manquant n'a pas pu être vu — et la marque ne porte que sur ceux qui ne le
/// sont pas encore, pour que le compte annoncé soit celui du geste.
class SeasonWatchedButton extends StatelessWidget {
  final List<HomeMediaItem> episodes;
  final bool busy;

  /// Reçoit les épisodes à changer et le sens du changement.
  final Future<void> Function(List<HomeMediaItem> episodes, bool watched)
      onSetWatched;

  const SeasonWatchedButton({
    super.key,
    required this.episodes,
    required this.onSetWatched,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final episode in episodes)
        if (episode.isAvailable && episode.media.type == MediaType.episode)
          episode,
    ];
    if (available.isEmpty) return const SizedBox.shrink();

    final unwatched = [
      for (final episode in available)
        if (!episode.isFinished) episode,
    ];
    final allWatched = unwatched.isEmpty;

    return TextButton.icon(
      onPressed: busy
          ? null
          : () => onSetWatched(allWatched ? available : unwatched, !allWatched),
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              allWatched
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              size: 18,
            ),
      label: Text(allWatched ? 'Saison vue' : 'Marquer la saison vue'),
      style: TextButton.styleFrom(
        foregroundColor:
            allWatched ? AppColors.success : AppColors.textSecondary,
      ),
    );
  }
}
