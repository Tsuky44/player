import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';

/// Pastille d'avancement posée en haut à droite d'une affiche.
///
/// Deux états seulement, parce que c'est tout ce qu'une vignette de catalogue
/// peut dire d'un coup d'œil : « vu » (coche verte, le même vert que le bouton
/// « Marquer vu » des fiches) et « en cours » (pastille bleue portant le nombre
/// d'épisodes restants). Un titre jamais commencé ne porte rien : c'est l'état
/// par défaut de la bibliothèque, et le marquer bruiterait toutes les affiches.
class WatchBadge extends StatelessWidget {
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
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 6),
        decoration: BoxDecoration(
          color: isWatched ? AppColors.success : AppColors.accent,
          borderRadius: BorderRadius.circular(11),
          // L'affiche derrière peut être claire : sans ce liseré la pastille
          // s'y dissout.
          border: Border.all(color: Colors.black.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: label == null
            ? const Icon(Icons.check_rounded,
                size: 15, color: AppColors.onAccent)
            : Text(
                label,
                style: const TextStyle(
                  color: AppColors.onAccent,
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}
