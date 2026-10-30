import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/media_request.dart';
import '../../../l10n/tr.dart';
import '../../../widgets/global/detail_info_table.dart';

/// La colonne d'informations d'une fiche de demande : ce que MediaHub sait de
/// plus que la bibliothèque, le budget et le revenu.
class RequestInfoTable extends StatelessWidget {
  final RequestMediaDetails details;

  const RequestInfoTable({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    return DetailInfoTable(
      rating: details.rating,
      studios: details.studios,
      rows: [
        if (details.originalTitle != null &&
            details.originalTitle!.isNotEmpty &&
            details.originalTitle != details.title)
          (label: tr('Titre original'), value: details.originalTitle!),
        if (details.tmdbStatus != null &&
            details.tmdbStatus!.isNotEmpty &&
            details.tmdbStatus != 'unknown')
          (label: tr('Statut'), value: detailStatusLabel(details.tmdbStatus!)),
        if (details.releaseDate != null && details.releaseDate!.isNotEmpty)
          (
            label: tr('Date de sortie'),
            value: detailDateLabel(details.releaseDate!)
          ),
        if (details.budget != null && details.budget! > 0)
          (label: tr('Budget'), value: _formatMoney(details.budget!)),
        if (details.revenue != null && details.revenue! > 0)
          (label: tr('Revenu'), value: _formatMoney(details.revenue!)),
        if (details.originalLanguage != null &&
            details.originalLanguage!.isNotEmpty)
          (
            label: tr('Langue originale'),
            value: details.originalLanguage!.toUpperCase()
          ),
        if (details.countries.isNotEmpty)
          (label: tr('Pays de production'), value: details.countries.first),
        if (details.numberOfSeasons != null && details.numberOfSeasons! > 0)
          (label: tr('Saisons'), value: '${details.numberOfSeasons}'),
        if (details.numberOfEpisodes != null && details.numberOfEpisodes! > 0)
          (label: tr('Épisodes'), value: '${details.numberOfEpisodes}'),
      ],
    );
  }

  String _formatMoney(int amount) {
    final formatted = NumberFormat('#,###', 'fr_FR').format(amount);
    return '$formatted \$US';
  }
}
