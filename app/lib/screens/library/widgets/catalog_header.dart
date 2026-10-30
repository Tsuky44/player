import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';
import '../../../widgets/global/poster_grid_zoom_slider.dart';

/// L'en-tête d'un catalogue : le titre, le nombre de titres et le tri, sur une
/// seule ligne.
///
/// Ils étaient empilés sur trois — le titre, puis une boîte de tri seule à
/// droite, puis le compte en dessous à gauche — soit une centaine de pixels
/// perdus avant la première affiche, et un menu déroulant Material encadré au
/// milieu d'un écran de verre.
class CatalogHeader<T> extends StatelessWidget {
  final String title;

  /// « 28 films ». Null pendant le chargement.
  final String? countLabel;
  final Map<T, String> sortOptions;
  final T sort;
  final ValueChanged<T> onSortChanged;
  final bool compact;

  const CatalogHeader({
    super.key,
    required this.title,
    required this.countLabel,
    required this.sortOptions,
    required this.sort,
    required this.onSortChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final zoom = PosterGridZoomSlider.availableIn(context);
    final row = _row(context, inlineZoom: zoom && !compact);
    // Sur un téléphone la ligne est pleine avec le titre, le compte et le tri :
    // le curseur de densité passe dessous, à droite.
    if (!zoom || !compact) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        const Align(
          alignment: Alignment.centerRight,
          child: PosterGridZoomSlider(width: 110),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, {required bool inlineZoom}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        // Le titre et le compte prennent toute la place restante (Expanded) pour
        // que le tri reste collé au bord droit : un Flexible suivi d'un Spacer
        // se partageraient le vide, et le tri s'arrêterait au milieu de la ligne.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // Le titre est le nom qu'un administrateur a donné à sa
              // bibliothèque : sa longueur n'est pas la nôtre, il se coupe
              // plutôt que de déborder.
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: compact ? 28 : 34,
                        letterSpacing: compact ? -0.6 : -0.9,
                      ),
                ),
              ),
              if (countLabel != null) ...[
                const SizedBox(width: 12),
                Text(
                  countLabel!,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (inlineZoom) ...[
          // La ligne est alignée sur la ligne de base du texte, que le
          // curseur n'a pas : on place son centre à hauteur des minuscules.
          const Baseline(
            baseline: 19,
            baselineType: TextBaseline.alphabetic,
            child: PosterGridZoomSlider(),
          ),
          const SizedBox(width: 20),
        ],
        PopupMenuButton<T>(
          tooltip: tr('Trier'),
          initialValue: sort,
          position: PopupMenuPosition.under,
          onSelected: onSortChanged,
          itemBuilder: (_) => [
            for (final entry in sortOptions.entries)
              CheckedPopupMenuItem<T>(
                value: entry.key,
                checked: entry.key == sort,
                child: Text(tr(entry.value)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(sortOptions[sort] ?? ''),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(AppIcons.sort,
                    size: 18, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
