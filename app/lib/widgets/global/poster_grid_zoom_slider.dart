import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../tv/tv_mode.dart';
import '../../utils/poster_grid_zoom.dart';
import '../../utils/responsive.dart';
import 'app_slider.dart';

/// Le curseur du nombre d'affiches par ligne : le pendant, à la souris et au
/// doigt, du Ctrl + molette de `PosterGridZoomRegion`. À gauche, beaucoup de
/// petites affiches ; à droite, peu de grandes, comme le curseur de taille des
/// vignettes d'un explorateur de fichiers.
///
/// Se pose dans l'en-tête d'une page en grille, sous une région de zoom : il
/// lit et règle le même écart que la molette, et les grilles suivent.
/// Absent sur un téléviseur, où la télécommande n'a pas de molette et où un
/// curseur de plus ne ferait qu'un arrêt de plus pour le focus.
class PosterGridZoomSlider extends StatelessWidget {
  const PosterGridZoomSlider({super.key, this.width = 140});

  /// Largeur de la piste, icônes non comprises.
  final double width;

  /// Faux sur un téléviseur : l'appelant s'en sert pour ne pas laisser d'espace
  /// vide à la place du curseur.
  static bool availableIn(BuildContext context) => !TvScope.of(context);

  static const SliderThemeData _theme = SliderThemeData(
    trackHeight: 3,
    activeTrackColor: AppColors.textSecondary,
    inactiveTrackColor: Color(0x1FFFFFFF),
    thumbColor: Colors.white,
    overlayColor: Color(0x1FFFFFFF),
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
  );

  static const int _span =
      PosterGridZoom.minColumns + PosterGridZoom.maxColumns;

  @override
  Widget build(BuildContext context) {
    if (!availableIn(context)) return const SizedBox.shrink();
    final zoom = PosterGridZoomScope.watch(context);
    final columns = zoom.columns;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(AppIcons.postersSmall, size: 16, color: AppColors.textMuted),
        SizedBox(
          width: width,
          child: SliderTheme(
            data: _theme,
            child: AppSlider(
              // Vers la droite, les affiches grandissent : donc moins de
              // colonnes. La valeur est le nombre de colonnes, à l'envers.
              value: (_span - columns).toDouble(),
              min: PosterGridZoom.minColumns.toDouble(),
              max: PosterGridZoom.maxColumns.toDouble(),
              semanticLabel: tr('Affiches par ligne'),
              label: tr('{0} par ligne', [columns]),
              onChanged: (v) => zoom.setColumns(_span - v.round()),
            ),
          ),
        ),
        const Icon(AppIcons.postersLarge, size: 16, color: AppColors.textMuted),
      ],
    );
  }
}

/// Une rangée à droite, entre l'en-tête d'une page et sa grille, pour les
/// pages dont l'en-tête n'a pas de ligne où loger le curseur. Vide sur un
/// téléviseur.
class SliverPosterGridZoomBar extends StatelessWidget {
  const SliverPosterGridZoomBar({super.key});

  /// L'espace que la barre ajoute au-dessus de la grille ; les pages qui la
  /// posent en retranchent autant du haut de leur grille.
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    if (!PosterGridZoomSlider.availableIn(context)) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: AppLayout.pageInsets(context),
        child: SizedBox(
          height: height,
          child: Align(
            alignment: Alignment.centerRight,
            child: PosterGridZoomSlider(
              width: AppLayout.isCompact(context) ? 110 : 140,
            ),
          ),
        ),
      ),
    );
  }
}
