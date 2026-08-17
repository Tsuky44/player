import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/format.dart';
import 'end_card_chrome.dart';

/// Page shown when the last episode the server holds is not the last of its
/// season — a show still airing week by week, or a season imported in part.
///
/// It replaces [NextSeasonOverlay] in that position. Offering the season after
/// one still running would skip over the episodes still to come, and a request
/// for it would only pull down something barely announced.
///
/// Purely informative: seasons are requested whole, so there is no per-episode
/// action to offer. What it can do is say which episode is missing, what it is
/// about, and when it lands.
class UpcomingEpisodeOverlay extends StatelessWidget {
  final UpcomingEpisode episode;
  final VoidCallback onDismiss;

  /// Set only when the library still holds something to play after this — the
  /// first episode of a later season. The page then carries the way forward,
  /// since it replaces the auto-advance pill it would otherwise sit on top of.
  final VoidCallback? onPlayNext;

  /// Width reserved on the left for the shrunk video.
  final double videoInset;

  const UpcomingEpisodeOverlay({
    super.key,
    required this.episode,
    required this.onDismiss,
    this.onPlayNext,
    this.videoInset = 0,
  });

  @override
  Widget build(BuildContext context) {
    return EndCardPanel(
      backdropUrl: episode.stillUrl,
      videoInset: videoInset,
      eyebrow: EndCardEyebrow(
        label: 'ÉPISODE ${episode.number} PAS ENCORE DISPONIBLE',
        onDismiss: onDismiss,
      ),
      body: _Body(episode: episode),
      actions: _Actions(onDismiss: onDismiss, onPlayNext: onPlayNext),
    );
  }
}

class _Body extends StatelessWidget {
  final UpcomingEpisode episode;

  const _Body({required this.episode});

  @override
  Widget build(BuildContext context) {
    final still = episode.stillUrl;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (still != null && still.isNotEmpty) ...[
          // 16:9, unlike the season page's poster: a still is a frame of the
          // episode, and letterboxing it into a poster slot would crop it.
          EndCardArtwork(url: still, width: 264, height: 149),
          const SizedBox(width: 24),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _header(episode),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                episode.name.isNotEmpty
                    ? episode.name
                    : 'Épisode ${episode.number}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 14),
              _MetaRow(episode: episode),
              const SizedBox(height: 16),
              Text(
                _description(episode),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _header(UpcomingEpisode episode) {
    final position = 'S${episode.seasonNumber} · Épisode ${episode.number}';
    if (episode.showTitle.isEmpty) return position;
    return '${episode.showTitle.toUpperCase()}  —  $position';
  }

  /// TMDB withholds the synopsis of episodes that have not aired far more often
  /// than not, so the fallback carries the real news: why the episode is not
  /// there, and whether waiting is all there is to do.
  static String _description(UpcomingEpisode episode) {
    if (episode.overview?.isNotEmpty == true) return episode.overview!;
    if (episode.isUnaired) {
      return 'Cet épisode n’est pas encore sorti. Il rejoindra le serveur peu '
          'après sa diffusion.';
    }
    return 'Cet épisode est sorti mais n’est pas encore sur le serveur. Il '
        'arrivera dès qu’il aura été récupéré.';
  }
}

class _MetaRow extends StatelessWidget {
  final UpcomingEpisode episode;

  const _MetaRow({required this.episode});

  @override
  Widget build(BuildContext context) {
    // "Sortie prévue le 12 sept. 2025" before the date, "Sorti le …" after it.
    final airDate = formatAirDate(episode.airDate);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (episode.seasonEpisodes > 0)
          EndCardPill(
            label: 'Épisode ${episode.number} sur ${episode.seasonEpisodes}',
            icon: Icons.playlist_play_rounded,
          ),
        if (airDate != null)
          EndCardPill(
            label: airDate,
            icon: Icons.event_outlined,
            accent: episode.isUnaired,
          )
        else
          const EndCardPill(
            label: 'Date inconnue',
            icon: Icons.event_busy_outlined,
          ),
        const EndCardPill(
          label: 'Absent du serveur',
          icon: Icons.cloud_off_outlined,
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  final VoidCallback onDismiss;
  final VoidCallback? onPlayNext;

  const _Actions({required this.onDismiss, this.onPlayNext});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onPlayNext != null) ...[
          EndCardNextEpisodeButton(onTap: onPlayNext!, primary: true),
          const SizedBox(width: 8),
        ],
        TextButton(
          onPressed: onDismiss,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          ),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
