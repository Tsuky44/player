import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import 'end_card_chrome.dart';

/// End-of-season page, shown when the season that follows is not on the server
/// *and* has never been requested — the server withholds the payload otherwise,
/// so the credits are never interrupted just to restate a pending download.
///
/// Deliberately unlike [NextEpisodeOverlay]: no countdown and no automatic
/// action. Sending a request is a commitment, so it always waits for a tap.
///
/// The same page also runs one episode early, on the outro of the penultimate
/// episode ([onPlayNext] set): asking then lets the download and the import run
/// while the finale plays. In that mode it also carries the way forward, since
/// it replaces the auto-advance pill it would otherwise sit on top of.
///
/// It never runs while the current season is still airing — that case belongs
/// to [UpcomingEpisodeOverlay], since a season that has episodes left is not
/// one to look past.
class NextSeasonOverlay extends StatelessWidget {
  final NextSeason season;
  final bool submitting;
  final VoidCallback onRequest;
  final VoidCallback onDismiss;

  /// Set only when an episode still follows this one — the early offer.
  final VoidCallback? onPlayNext;

  /// Width reserved on the left for the shrunk video.
  final double videoInset;

  const NextSeasonOverlay({
    super.key,
    required this.season,
    required this.submitting,
    required this.onRequest,
    required this.onDismiss,
    this.onPlayNext,
    this.videoInset = 0,
  });

  bool get _lookahead => onPlayNext != null;

  String get _eyebrowLabel {
    if (season.isRequested) return 'DEMANDE ENVOYÉE';
    if (_lookahead) return 'PLUS QU’UN ÉPISODE';
    return 'SAISON TERMINÉE';
  }

  @override
  Widget build(BuildContext context) {
    return EndCardPanel(
      backdropUrl: season.posterUrl,
      videoInset: videoInset,
      eyebrow: EndCardEyebrow(label: _eyebrowLabel, onDismiss: onDismiss),
      body: _Body(season: season, lookahead: _lookahead),
      actions: _Actions(
        season: season,
        submitting: submitting,
        onRequest: onRequest,
        onDismiss: onDismiss,
        onPlayNext: onPlayNext,
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final NextSeason season;
  final bool lookahead;

  const _Body({required this.season, required this.lookahead});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (season.posterUrl != null) ...[
          EndCardArtwork(url: season.posterUrl!, width: 132, height: 198),
          const SizedBox(width: 24),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (season.showTitle.isNotEmpty) ...[
                Text(
                  season.showTitle.toUpperCase(),
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
              ],
              Text(
                season.name.isNotEmpty ? season.name : 'Saison ${season.number}',
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
              _MetaRow(season: season, lookahead: lookahead),
              const SizedBox(height: 16),
              Text(
                _description(season, lookahead),
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

  static String _description(NextSeason season, bool lookahead) {
    if (season.isRequested) {
      return lookahead
          ? 'Demande envoyée. Le téléchargement se lance pendant que tu '
              'termines l’épisode en cours.'
          : 'Cette saison a déjà été demandée. Elle apparaîtra dans ta '
              'bibliothèque dès qu’elle sera disponible.';
    }
    if (lookahead) {
      return 'Il ne reste plus qu’un épisode disponible, et la saison '
          '${season.number} n’est pas sur le serveur. La demander maintenant '
          'lui laisse le temps de se télécharger pendant que tu le regardes.';
    }
    if (season.overview?.isNotEmpty == true) return season.overview!;
    return 'Cette saison n’est pas encore sur le serveur.';
  }
}

/// Episode count, air year and request state as compact pills.
class _MetaRow extends StatelessWidget {
  final NextSeason season;
  final bool lookahead;

  const _MetaRow({required this.season, required this.lookahead});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (lookahead)
          const EndCardPill(
            label: '1 épisode restant',
            icon: Icons.playlist_play_rounded,
          ),
        if (season.episodeCount > 0)
          EndCardPill(label: '${season.episodeCount} épisodes'),
        if (season.isRequested)
          const EndCardPill(
            label: 'En attente',
            icon: Icons.hourglass_top_rounded,
            accent: true,
          )
        else if (!season.canRequest)
          const EndCardPill(
            label: 'Indisponible',
            icon: Icons.cloud_off_outlined,
          )
        else
          const EndCardPill(
            label: 'Absente du serveur',
            icon: Icons.cloud_off_outlined,
          ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  final NextSeason season;
  final bool submitting;
  final VoidCallback onRequest;
  final VoidCallback onDismiss;
  final VoidCallback? onPlayNext;

  const _Actions({
    required this.season,
    required this.submitting,
    required this.onRequest,
    required this.onDismiss,
    this.onPlayNext,
  });

  @override
  Widget build(BuildContext context) {
    if (!season.canRequest) {
      // The request just went through: informative only. The way forward still
      // belongs here when an episode follows, since this page stands in for the
      // auto-advance pill.
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

    return Row(
      children: [
        ElevatedButton.icon(
          onPressed: submitting ? null : onRequest,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          icon: submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_rounded, size: 19),
          label: Text('Demander la saison ${season.number}'),
        ),
        const SizedBox(width: 8),
        if (onPlayNext != null) ...[
          EndCardNextEpisodeButton(
            onTap: onPlayNext!,
            primary: false,
            enabled: !submitting,
          ),
          const SizedBox(width: 8),
        ],
        TextButton(
          onPressed: submitting ? null : onDismiss,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          ),
          child: const Text('Non merci'),
        ),
      ],
    );
  }
}
