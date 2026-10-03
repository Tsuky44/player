import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import '../../utils/responsive.dart';

/// Les crédits d'une fiche : réalisation, scénario, studios.
///
/// Les genres et le synopsis vivaient ici aussi ; ils sont dans l'en-tête
/// (ligne de métadonnées et [DetailSynopsis]). Sans aucun crédit, la section
/// ne prend pas de place.
class DetailFactsSection extends StatelessWidget {
  final MediaDetails? details;

  const DetailFactsSection({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    final director = details?.director;
    final writers = details?.writers ?? const <String>[];
    final studios = details?.studios ?? const <String>[];
    final hasDirector = director != null && director.isNotEmpty;
    if (!hasDirector && writers.isEmpty && studios.isEmpty) {
      return const SizedBox.shrink();
    }

    final pad = AppLayout.pagePadding(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 28, pad, 12),
      child: Wrap(
        spacing: AppLayout.isCompact(context) ? 24 : 48,
        runSpacing: 16,
        children: [
          if (hasDirector) _FactColumn(label: 'Réalisation', values: [director]),
          if (writers.isNotEmpty)
            _FactColumn(label: 'Scénario', values: writers),
          if (studios.isNotEmpty) _FactColumn(label: 'Studios', values: studios),
        ],
      ),
    );
  }
}

class _FactColumn extends StatelessWidget {
  final String label;
  final List<String> values;

  const _FactColumn({required this.label, required this.values});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: AppType.caption,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          values.join(', '),
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: AppType.body,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
