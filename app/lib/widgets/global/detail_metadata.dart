import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';

/// La ligne de métadonnées d'une fiche : « 2024 · 2 h 46 min · ★ 8,3 ».
///
/// Elle se lisait en boîtes grises à liseré, une par valeur — un habillage de
/// formulaire pour ce qui n'est que du texte. Les pages de films haut de gamme
/// l'écrivent en ligne, séparée par des points médians ; les boîtes restent
/// aux badges techniques ([TechBadge]), qui sont des labels, pas des phrases.
List<Widget> buildMetadataChips({
  required MediaType type,
  String? releaseDate,
  int runtimeMinutes = 0,
  int durationSeconds = 0,
  double rating = 0,
  int seasons = 0,
  String? statusLabel,
}) {
  final year = extractYear(releaseDate);
  final items = <Widget>[];
  if (year != null) items.add(MetadataText(year));

  if (type == MediaType.show) {
    if (seasons > 0) {
      items.add(MetadataText('$seasons saison${seasons > 1 ? 's' : ''}'));
    }
  } else {
    final seconds = runtimeMinutes > 0 ? runtimeMinutes * 60 : durationSeconds;
    if (seconds > 0) items.add(MetadataText(formatDuration(seconds)));
  }

  if (rating > 0) items.add(RatingBadge(rating: rating));
  if (statusLabel != null && statusLabel.isNotEmpty) {
    items.add(MetadataText(statusLabel));
  }
  return items;
}

/// Une valeur de la ligne de métadonnées.
class MetadataText extends StatelessWidget {
  final String label;

  const MetadataText(this.label, {super.key});

  static const TextStyle style = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) => Text(label, style: style);
}

/// Le point médian entre deux valeurs de [buildMetadataChips].
class MetadataDot extends StatelessWidget {
  const MetadataDot({super.key});

  @override
  Widget build(BuildContext context) => Text(
        '·',
        style: MetadataText.style.copyWith(color: AppColors.textMuted),
      );
}

/// La note TMDB : une étoile et la valeur, écrite avec une virgule.
class RatingBadge extends StatelessWidget {
  final double rating;

  const RatingBadge({super.key, required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, color: AppColors.rating, size: 16),
        const SizedBox(width: 3),
        Text(
          rating.toStringAsFixed(1).replaceAll('.', ','),
          style: MetadataText.style.copyWith(color: AppColors.textPrimary),
        ),
      ],
    );
  }
}

/// Un genre, sous le synopsis.
///
/// En pilule bleue il prenait la couleur d'accent — celle du focus et de la
/// progression — pour une information qui n'est pas cliquable. Neutre, il se
/// range avec le reste du texte.
class GenrePill extends StatelessWidget {
  final String label;

  const GenrePill({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// Un badge technique : « 4K », « Dolby Vision », « Dolby Atmos », « 5.1 ».
///
/// Contour fin, capitales serrées : la grammaire des jaquettes et des
/// boutiques de films, là où la qualité d'un fichier se lit d'un coup d'œil.
class TechBadge extends StatelessWidget {
  final String label;

  const TechBadge(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.38)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          height: 1.1,
        ),
      ),
    );
  }
}

/// Les badges d'un fichier, du plus parlant au moins parlant : définition,
/// dynamique, son immersif, canaux. Le codec n'y est pas — « HEVC » ne dit
/// rien à qui choisit un film ; il reste dans les informations techniques.
List<String> techBadgesFor(MediaTracks? tracks) {
  if (tracks == null) return const [];
  final video = tracks.video;
  final badges = <String>[
    if (video != null && video.resolutionLabel.isNotEmpty)
      video.resolutionLabel,
    if (video != null && video.hdrLabel.isNotEmpty) video.hdrLabel,
  ];

  final audio = tracks.audio;
  final spatial = audio
      .map((a) => a.spatialFormat)
      .firstWhere((f) => f.isNotEmpty, orElse: () => '');
  if (spatial == 'atmos') badges.add('Dolby Atmos');
  if (spatial == 'dtsx') badges.add('DTS:X');

  final maxChannels =
      audio.fold<int>(0, (max, a) => a.channels > max ? a.channels : max);
  if (maxChannels >= 8) {
    badges.add('7.1');
  } else if (maxChannels >= 6) {
    badges.add('5.1');
  }
  return badges;
}

/// Le titre d'une section de fiche (« Distribution », « Épisodes »…).
///
/// En 22 px extra-gras, chaque section criait aussi fort que le titre du
/// film. Plus petit et demi-gras, il range la page sans lui disputer la
/// vedette.
TextStyle? detailSectionTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: AppColors.textPrimary,
        );
