import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// L'en-tête d'un catalogue : le titre, le nombre de titres et le tri, sur une
/// seule ligne.
///
/// Ils étaient empilés sur trois — le titre, puis une boîte de tri seule à
/// droite, puis le compte en dessous à gauche — soit une centaine de pixels
/// perdus avant la première affiche, et un menu déroulant Material encadré au
/// milieu d'un écran de verre.
class CatalogHeader<T> extends StatelessWidget {
  final String title;

  /// « 28 films ». Null pendant le chargement.
  final String? countLabel;
  final Map<T, String> sortOptions;
  final T sort;
  final ValueChanged<T> onSortChanged;
  final bool compact;

  const CatalogHeader({
    super.key,
    required this.title,
    required this.countLabel,
    required this.sortOptions,
    required this.sort,
    required this.onSortChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: compact ? 28 : 34,
                letterSpacing: compact ? -0.6 : -0.9,
              ),
        ),
        if (countLabel != null) ...[
          const SizedBox(width: 12),
          Text(
            countLabel!,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        const Spacer(),
        PopupMenuButton<T>(
          tooltip: 'Trier',
          initialValue: sort,
          position: PopupMenuPosition.under,
          onSelected: onSortChanged,
          itemBuilder: (_) => [
            for (final entry in sortOptions.entries)
              CheckedPopupMenuItem<T>(
                value: entry.key,
                checked: entry.key == sort,
                child: Text(entry.value),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sortOptions[sort] ?? '',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.unfold_more_rounded,
                    size: 18, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
