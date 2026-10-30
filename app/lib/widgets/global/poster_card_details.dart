import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_type.dart';
import 'poster_card.dart';

/// Le cartouche d'une affiche pointée, le même pour la bibliothèque et les
/// demandes : titre, pastille de type avec [facts], puis le début du résumé.
class PosterCardDetails extends StatelessWidget {
  final String title;
  final String typeLabel;

  /// « 2024  ·  ★ 8.3 », ou le rôle dans une filmographie.
  final String? facts;
  final String? overview;

  const PosterCardDetails({
    super.key,
    required this.title,
    required this.typeLabel,
    this.facts,
    this.overview,
  });

  @override
  Widget build(BuildContext context) {
    final facts = this.facts;
    final overview = this.overview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HoverLine(
          rank: 0,
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: AppType.body,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 6),
        HoverLine(
          rank: 1,
          child: Row(
            children: [
              _TypePill(label: typeLabel),
              if (facts != null && facts.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    facts,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppType.micro,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (overview != null && overview.isNotEmpty) ...[
          const SizedBox(height: 6),
          HoverLine(
            rank: 2,
            child: Text(
              overview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppType.caption,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Pastille de verre « Film » / « Série ». Fond uni plutôt que flouté : elle
/// apparaît sur chaque carte pointée, et un flou par carte se paierait à
/// chaque image d'un déplacement du focus.
class _TypePill extends StatelessWidget {
  final String label;

  const _TypePill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: AppType.micro,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
