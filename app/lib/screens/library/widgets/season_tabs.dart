import 'package:flutter/material.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_motion.dart';
import '../../../tv/tv_focus.dart';
import '../../../tv/tv_focus_memory.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';

/// « Saison 1 », « Saison 2 »… tel que la fiche l'écrit partout.
String seasonLabel(Media season) {
  final number = season.effectiveSeasonNumber;
  return number != null && number > 0 ? tr('Saison {0}', [number]) : season.title;
}

/// Les saisons d'une série, en onglets.
///
/// C'était un menu déroulant : il fallait l'ouvrir pour savoir combien de
/// saisons existaient et lesquelles manquaient. En onglets, tout se lit sans
/// geste — et les saisons absentes du serveur le disent sur l'onglet même.
/// Sur un téléviseur, la rangée se souvient de l'onglet où était la
/// télécommande ([TvFocusMemory]).
class SeasonTabs extends StatelessWidget {
  final List<Media> seasons;
  final Media? selected;
  final ValueChanged<Media> onSelected;

  const SeasonTabs({
    super.key,
    required this.seasons,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusMemory(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(
          children: [
            for (final season in seasons) ...[
              _SeasonTab(
                season: season,
                selected: identical(season, selected),
                onTap: () => onSelected(season),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _SeasonTab extends StatelessWidget {
  final Media season;
  final bool selected;
  final VoidCallback onTap;

  const _SeasonTab({
    required this.season,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = seasonLabel(season);
    final missing = !season.isAvailable;
    final text = !missing
        ? label
        : season.isRequested
            ? tr('{0} · demandée', [label])
            : '$label · manquante';
    final radius = BorderRadius.circular(20);

    return TvFocusable(
      onSelect: onTap,
      borderRadius: radius,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.fade(context, AppMotion.micro),
            curve: AppMotion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.textPrimary
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: radius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (missing) ...[
                  Icon(
                    season.isRequested
                        ? AppIcons.pending
                        : AppIcons.cloudOff,
                    size: 14,
                    color:
                        selected ? AppColors.background : AppColors.textMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  text,
                  style: TextStyle(
                    color: selected
                        ? AppColors.background
                        : missing
                            ? AppColors.textMuted
                            : AppColors.textSecondary,
                    fontSize: AppType.body,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
