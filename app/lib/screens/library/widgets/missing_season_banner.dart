import 'package:flutter/material.dart';
import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/format.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';

/// Panel shown under the season picker when the selected season is not on the
/// server, or is there but incomplete (still airing, files missing). It offers the request when MediaHub allows it, states that the
/// season is already requested when it is, and stays purely informative when
/// MediaHub could not be consulted — never a button that would do nothing.
class MissingSeasonBanner extends StatelessWidget {
  final Media season;

  /// How many seasons of this show could be requested right now. A second entry
  /// point for multi-selection only appears when it would add something.
  final int requestableCount;

  final bool submitting;
  final VoidCallback onRequest;
  final VoidCallback onRequestMore;

  const MissingSeasonBanner({
    super.key,
    required this.season,
    required this.requestableCount,
    required this.submitting,
    required this.onRequest,
    required this.onRequestMore,
  });

  @override
  Widget build(BuildContext context) {
    final seasonNumber = season.effectiveSeasonNumber ?? 0;
    // Une saison présente mais incomplète : sa date et son résumé sont déjà
    // ceux de la page, seul l'état de la demande reste à dire.
    final held = season.isAvailable;
    final airDate = held ? null : formatAirDate(season.releaseDate);
    final String title;
    if (held) {
      title = season.isRequested
          ? tr('Saison demandée, les épisodes manquants arriveront')
          : tr('Saison incomplète sur le serveur');
    } else {
      title = season.isRequested
          ? tr('Saison déjà demandée, pas encore disponible')
          : tr('Saison manquante sur le serveur');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                season.isRequested
                    ? AppIcons.pending
                    : AppIcons.cloudOff,
                size: 18,
                color:
                    season.isRequested ? AppColors.accentMuted : AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: AppType.body,
                  ),
                ),
              ),
              if (season.episodeCount != null && season.episodeCount! > 0)
                Text(
                  tr('{0} épisodes', [season.episodeCount]),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: AppType.footnote,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          if (!held && season.overview?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text(
              season.overview!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppType.subhead,
                height: 1.45,
              ),
            ),
          ],
          if (airDate != null) ...[
            const SizedBox(height: 8),
            Text(
              airDate,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppType.footnote,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (season.canRequest) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: submitting ? null : onRequest,
                  icon: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(AppIcons.download, size: 18),
                  label: Text(
                    seasonNumber > 0
                        ? tr('Demander la saison {0}', [seasonNumber])
                        : tr('Demander cette saison'),
                  ),
                ),
                if (requestableCount > 1) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: submitting ? null : onRequestMore,
                    child: Text(tr('Demander plusieurs saisons…')),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
