import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';

/// Pastille d'avancement posée en haut à droite d'une affiche.
///
/// Deux états seulement, parce que c'est tout ce qu'une vignette de catalogue
/// peut dire d'un coup d'œil : « vu » (coche) et « en cours » (nombre d'épisodes
/// restants). Un titre jamais commencé ne porte rien : c'est l'état par défaut
/// de la bibliothèque, et le marquer bruiterait toutes les affiches.
///
/// Les deux états partagent le même fond — du verre sombre, comme le reste du
/// chrome de l'app — et ne se distinguent que par ce qu'ils portent. Une
/// pastille pleine et colorée pèse autant qu'un titre dans une grille ; sur
/// quarante affiches, elle prend le dessus sur les affiches elles-mêmes. La
/// couleur reste donc réduite au glyphe.
class WatchBadge extends StatelessWidget {
  /// Hauteur commune aux deux états : la coche et le compteur doivent s'aligner
  /// quand ils se suivent dans une même grille.
  static const double _height = 24;

  /// Vert adouci vers le blanc : le vert système à pleine saturation vibre sur
  /// un fond quasi noir, et la pastille doit se lire sans crier.
  static final Color _watchedGlyph =
      Color.lerp(AppColors.success, Colors.white, 0.22)!;

  /// Nombre d'épisodes restants, affiché pour l'état « en cours ». Null pour
  /// « vu », et pour un film en cours — un film n'a pas de reste à compter, sa
  /// barre de progression le dit déjà.
  final int? remaining;

  const WatchBadge.watched({super.key}) : remaining = null;

  const WatchBadge.remaining(int this.remaining, {super.key});

  /// Pastille correspondant à [media], ou null s'il n'y a rien à annoncer.
  ///
  /// [watched] tranche le cas des films, dont l'état « vu » vient de leur
  /// progression et non du média lui-même.
  static Widget? forMedia(Media media, {bool watched = false}) {
    if (media.type == MediaType.show) {
      if (media.isFullyWatched) return const WatchBadge.watched();
      if (media.isPartiallyWatched && media.remainingEpisodeCount > 0) {
        return WatchBadge.remaining(media.remainingEpisodeCount);
      }
      // Série entamée dont il ne reste rien de disponible à voir : la coche
      // serait un mensonge (tout n'est pas terminé), le décompte aussi.
      return null;
    }
    return watched ? const WatchBadge.watched() : null;
  }

  @override
  Widget build(BuildContext context) {
    final isWatched = remaining == null;
    final label = isWatched ? null : (remaining! > 99 ? '99+' : '$remaining');

    return Semantics(
      label: isWatched ? 'Vu' : '$remaining épisode(s) à voir',
      child: Container(
        height: _height,
        constraints: const BoxConstraints(minWidth: _height),
        padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Un dégradé très court plutôt qu'un aplat : c'est ce qui empêche la
          // pastille de se lire comme un sticker collé sur l'affiche.
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF22A2A2E), Color(0xF2121214)],
          ),
          borderRadius: BorderRadius.circular(_height / 2),
          // Filet blanc, pas noir : le contraste contre une affiche claire vient
          // des ombres ci-dessous, et un cerne sombre salit le fond.
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.8,
          ),
          boxShadow: [
            // Deux couches : une courte qui décolle la pastille du fond, une
            // large et diffuse qui lui donne son poids. Une ombre unique et
            // franche est exactement ce qui faisait « autocollant ».
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: label == null
            ? Icon(Icons.check_rounded, size: 15, color: _watchedGlyph)
            : Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
      ),
    );
  }
}
