import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';

class RequestInfoTable extends StatelessWidget {
  final RequestMediaDetails details;

  const RequestInfoTable({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    final rows = <_InfoRow>[
      if (details.originalTitle != null &&
          details.originalTitle!.isNotEmpty &&
          details.originalTitle != details.title)
        _InfoRow('Titre original', details.originalTitle!),
      if (details.tmdbStatus != null &&
          details.tmdbStatus!.isNotEmpty &&
          details.tmdbStatus != 'unknown')
        _InfoRow('Statut', _translateStatus(details.tmdbStatus!)),
      if (details.releaseDate != null && details.releaseDate!.isNotEmpty)
        _InfoRow('Date de sortie', _formatDate(details.releaseDate!)),
      if (details.budget != null && details.budget! > 0)
        _InfoRow('Budget', _formatMoney(details.budget!)),
      if (details.revenue != null && details.revenue! > 0)
        _InfoRow('Revenu', _formatMoney(details.revenue!)),
      if (details.originalLanguage != null &&
          details.originalLanguage!.isNotEmpty)
        _InfoRow('Langue originale', details.originalLanguage!.toUpperCase()),
      if (details.countries.isNotEmpty)
        _InfoRow('Pays de production', details.countries.first),
      if (details.numberOfSeasons != null && details.numberOfSeasons! > 0)
        _InfoRow('Saisons', '${details.numberOfSeasons}'),
      if (details.numberOfEpisodes != null && details.numberOfEpisodes! > 0)
        _InfoRow('Épisodes', '${details.numberOfEpisodes}'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ratingsHeader(details.rating),
          if (rows.isNotEmpty)
            ...[
              for (int i = 0; i < rows.length; i++) ...[
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          rows[i].label,
                          style: TextStyle(
                            fontSize: 12,
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
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          if (details.studios.isNotEmpty) ...[
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Studios',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final studio in details.studios.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        studio,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 11,
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

  Widget _ratingsHeader(double rating) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ratingBadge(
            label: 'IMDb',
            value: rating.toStringAsFixed(1),
            color: const Color(0xFFF5C518),
            textColor: Colors.black,
          ),
          const SizedBox(width: 28),
          _ratingBadge(
            label: 'TMDB',
            value: '${(rating * 10).round()}%',
            color: const Color(0xFF01D277),
            textColor: Colors.black,
          ),
        ],
      ),
    );
  }

  Widget _ratingBadge({
    required String label,
    required String value,
    required Color color,
    required Color textColor,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: textColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  String _translateStatus(String status) {
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
    return map[status] ?? status;
  }

  String _formatDate(String date) {
    try {
      final d = DateTime.parse(date);
      const months = [
        'janvier',
        'février',
        'mars',
        'avril',
        'mai',
        'juin',
        'juillet',
        'août',
        'septembre',
        'octobre',
        'novembre',
        'décembre'
      ];
      return '${d.day} ${months[d.month - 1]} ${d.year}';
    } catch (_) {
      return date;
    }
  }

  String _formatMoney(int amount) {
    final formatted = NumberFormat('#,###', 'fr_FR').format(amount);
    return '$formatted \$US';
  }
}

class _InfoRow {
  final String label;
  final String value;
  _InfoRow(this.label, this.value);
}
