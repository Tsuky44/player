import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';

/// Le libellé du bouton principal d'une fiche.
///
/// Deux verbes seulement — « Lecture » pour commencer, « Reprendre » pour
/// continuer — là où les fiches en avaient trois, en capitales (« LECTURE »,
/// « REPRENDRE », « REGARDER ») pour le même geste. Sur une série, le bouton
/// nomme l'épisode qu'il lance : sans ça, on ne savait pas si « Reprendre »
/// menait à S2 E4 ou à S3 E1.
///
/// [seasonOverride] est la saison telle que la fiche l'affiche, quand elle
/// diffère de celle que porte l'épisode (voir [Media.seasonEpisodeCodeWith]).
String detailPlayLabel({
  required bool resuming,
  Media? episode,
  int? seasonOverride,
}) {
  final verb = resuming ? 'Reprendre' : 'Lecture';
  if (episode == null) return verb;
  final number = episode.effectiveEpisodeNumber;
  if (number == null || number <= 0) return verb;
  final season = (seasonOverride != null && seasonOverride > 0)
      ? seasonOverride
      : episode.effectiveSeasonNumber;
  return season != null && season > 0
      ? '$verb S$season E$number'
      : '$verb E$number';
}

/// La rangée d'actions d'une fiche film ou série : le bouton de lecture, où
/// l'on en est, puis les actions secondaires.
///
/// Sur téléphone, la rangée d'une fiche film faisait près de 600 px pour 328
/// de place et débordait. Le bouton de lecture y prend désormais toute la
/// largeur, seul sur sa ligne, et les actions secondaires passent en icônes
/// sur la ligne d'après. Au-delà, tout tient dans un [Wrap] : entre 600 et
/// 900 px l'affiche occupe déjà la gauche de l'en-tête.
class DetailActions extends StatelessWidget {
  final String playLabel;

  /// Null quand il n'y a rien à lire : le bouton n'est alors pas affiché.
  final VoidCallback? onPlay;

  /// La télécommande arrive sur Lecture : sur une fiche ouverte depuis le
  /// canapé, il n'y a qu'une chose qu'on est venu faire.
  final bool autofocusPlay;

  /// Avancement entre 0 et 1, ou null quand rien n'est commencé.
  final double? progress;

  /// Ce que [progress] veut dire, en mots : « 1h 15min restantes ».
  final String? progressLabel;

  /// Les actions secondaires. Sur téléphone, en icônes seulement.
  final List<Widget> secondary;

  const DetailActions({
    super.key,
    required this.playLabel,
    required this.onPlay,
    this.autofocusPlay = false,
    this.progress,
    this.progressLabel,
    this.secondary = const [],
  });

  /// Les actions secondaires en disques de verre de 44 px, tous identiques :
  /// un bouton « Marquer vu » souligné à côté de trois icônes nues se lisait
  /// comme quatre composants de quatre bibliothèques différentes.
  static final ButtonStyle secondaryStyle = IconButton.styleFrom(
    backgroundColor: Colors.white.withValues(alpha: 0.08),
    foregroundColor: AppColors.textPrimary,
    hoverColor: Colors.white.withValues(alpha: 0.14),
    highlightColor: Colors.white.withValues(alpha: 0.18),
    fixedSize: const Size(44, 44),
    minimumSize: const Size(44, 44),
    iconSize: 21,
    shape: const CircleBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final secondary = this.secondary.isEmpty
        ? const <Widget>[]
        : [
            IconButtonTheme(
              data: IconButtonThemeData(style: secondaryStyle),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: this.secondary,
              ),
            ),
          ];
    final play = onPlay == null
        ? null
        : ElevatedButton.icon(
            autofocus: autofocusPlay,
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(playLabel, overflow: TextOverflow.ellipsis),
          );
    final progressLine = progress == null
        ? null
        : _ProgressLine(value: progress!, label: progressLabel);

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (play != null) play,
          if (progressLine != null) ...[
            const SizedBox(height: 12),
            progressLine,
          ],
          if (secondary.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...secondary,
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [if (play != null) play, ...secondary],
        ),
        if (progressLine != null) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: progressLine,
          ),
        ],
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final double value;
  final String? label;

  const _ProgressLine({required this.value, required this.label});

  static const double _height = 4;
  static const Radius _cap = Radius.circular(_height / 2);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.all(_cap),
            child: SizedBox(
              height: _height,
              child: Stack(
                children: [
                  // Sur le fond de la page et non sur une affiche : le rail de
                  // [ProgressPill], noir, y disparaîtrait avec la longueur
                  // totale qu'il sert à montrer.
                  Positioned.fill(
                    child:
                        ColoredBox(color: Colors.white.withValues(alpha: 0.14)),
                  ),
                  FractionallySizedBox(
                    widthFactor: value.clamp(0.02, 1.0),
                    heightFactor: 1,
                    child: const ColoredBox(color: AppColors.progress),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(width: 12),
          Text(
            label!,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ],
    );
  }
}
