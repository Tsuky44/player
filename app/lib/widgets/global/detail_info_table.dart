import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/long_date.dart';

/// Une ligne de [DetailInfoTable].
typedef DetailInfoRow = ({String label, String value});

/// Le statut TMDB (`Released`) dans la langue de l'interface.
String detailStatusLabel(String status) {
  const map = {
    'Released': 'Sorti',
    'Post Production': 'Post-production',
    'In Production': 'En production',
    'Planned': 'Planifié',
    'Rumored': 'Rumeur',
    'Canceled': 'Annulé',
    'Ended': 'Terminé',
    'Returning Series': 'En cours',
    'Pilot': 'Pilote',
  };
  final label = map[status];
  return label == null ? status : tr(label);
}

/// Une date de sortie écrite en toutes lettres, ou telle quelle si elle ne se
/// lit pas.
String detailDateLabel(String date) {
  final parsed = DateTime.tryParse(date);
  return parsed == null ? date : formatLongDate(parsed);
}

/// La colonne d'informations des fiches : la note, les faits, les studios.
class DetailInfoTable extends StatelessWidget {
  final double rating;
  final List<DetailInfoRow> rows;
  final List<String> studios;

  const DetailInfoTable({
    super.key,
    required this.rating,
    required this.rows,
    required this.studios,
  });

  /// La même colonne pour un titre de la bibliothèque.
  factory DetailInfoTable.forDetails(MediaDetails details) {
    final original = details.originalTitle;
    final status = details.status;
    final date = details.releaseDate;
    final language = details.originalLanguage;
    return DetailInfoTable(
      rating: details.voteAverage,
      studios: details.studios,
      rows: [
        if (original != null &&
            original.isNotEmpty &&
            original != details.title)
          (label: tr('Titre original'), value: original),
        if (status != null && status.isNotEmpty && status != 'unknown')
          (label: tr('Statut'), value: detailStatusLabel(status)),
        if (date != null && date.isNotEmpty)
          (label: tr('Date de sortie'), value: detailDateLabel(date)),
        if (language != null && language.isNotEmpty)
          (label: tr('Langue originale'), value: language.toUpperCase()),
        if (details.countries.isNotEmpty)
          (label: tr('Pays de production'), value: details.countries.first),
        if (details.numberOfSeasons > 0)
          (label: tr('Saisons'), value: '${details.numberOfSeasons}'),
        if (details.numberOfEpisodes > 0)
          (label: tr('Épisodes'), value: '${details.numberOfEpisodes}'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rating <= 0 && rows.isEmpty && studios.isEmpty) {
      return const SizedBox.shrink();
    }
    final divider =
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.06));
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rating > 0) _ratingHeader(rating),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0 || rating > 0) divider,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      rows[i].label,
                      style: TextStyle(
                        fontSize: AppType.footnote,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[i].value,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: AppType.footnote,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (studios.isNotEmpty) ...[
            if (rows.isNotEmpty || rating > 0) divider,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      tr('Studios'),
                      style: TextStyle(
                        fontSize: AppType.caption,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final studio in studios.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        studio,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: AppType.caption,
                          color: AppColors.textSecondary,
                          height: 1.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Seule la note TMDB : les deux API ne donnent rien d'autre. L'étiquette
  /// « IMDb » que portait cette colonne affichait la même note TMDB sous un
  /// autre nom.
  Widget _ratingHeader(double rating) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.tmdb,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              tr('TMDB'),
              style: const TextStyle(
                fontSize: AppType.micro,
                fontWeight: FontWeight.w900,
                color: Colors.black,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(rating * 10).round()}%',
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
