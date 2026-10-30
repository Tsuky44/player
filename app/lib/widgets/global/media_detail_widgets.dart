import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../navigation/detail_prefetch.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import 'app_network_image.dart';
import 'poster_card.dart';
import 'poster_card_details.dart';
import 'poster_rail.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// Saga/collection banner shown on a movie detail page ("Fait partie de la saga").
class CollectionSection extends StatelessWidget {
  final CollectionInfo collection;
  final VoidCallback onTap;

  const CollectionSection({
    super.key,
    required this.collection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 24, pad, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            Positioned.fill(
              child: AppNetworkImage(
                url: backdropImageUrl(collection.backdropUrl),
                fit: BoxFit.cover,
                alignment: Alignment.center,
                decodeWidth: MediaQuery.sizeOf(context).width,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      AppColors.background.withValues(alpha: 0.9),
                      AppColors.background.withValues(alpha: 0.55),
                    ],
                  ),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 16 : 20,
                    vertical: compact ? 18 : 22,
                  ),
                  child: Row(
                    children: [
                      const Icon(AppIcons.collection,
                          color: AppColors.accent, size: 26),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tr('FAIT PARTIE DE LA SAGA'),
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: AppType.caption,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              collection.name,
                              maxLines: compact ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: compact ? 16 : 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            tr('Voir la saga'),
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: AppType.subhead,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(width: 8),
                        Icon(
                          AppIcons.chevronRight,
                          color: AppColors.textPrimary.withValues(alpha: 0.85),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Poster card for filmography/collection grids. Owned titles are fully bright
/// and tappable; titles absent from the library are dimmed with a badge.
///
/// Toucher la carte ouvre la fiche par l'envol de l'affiche, depuis elle
/// ([openCatalogItem]).
class CatalogPosterCard extends StatelessWidget {
  final CatalogItem item;

  /// Le titre et le rôle sous l'affiche : une filmographie, dont la grille
  /// garde alors la place de ces deux lignes.
  final bool showMeta;

  const CatalogPosterCard({
    super.key,
    required this.item,
    this.showMeta = false,
  });

  @override
  Widget build(BuildContext context) {
    final character = item.character;
    final year = item.year;
    // Filmography cards lead with the role; everywhere else, the request
    // catalog's "année · ★ note" line.
    final facts = character != null && character.isNotEmpty
        ? character
        : [
            if (year != null && year.isNotEmpty) year,
            if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}',
          ].join('  ·  ');

    return PosterCard(
      posterUrl: cardPosterUrl(item.posterUrl),
      title: item.title,
      subtitle: facts,
      showMeta: showMeta,
      onTap: () => openCatalogItem(context, item),
      hoverDetails: PosterCardDetails(
        title: item.title,
        typeLabel: item.mediaType == MediaType.show ? tr('Série') : tr('Film'),
        facts: facts,
      ),
      // Only owned titles open a library page worth warming.
      onPrefetch: item.isOwned
          ? () => DetailPrefetch.warm(context, item.toLocalMedia())
          : null,
      dimmed: !item.isOwned,
      overlays: [
        if (!item.isOwned)
          const Positioned(top: 8, right: 8, child: _UnavailableBadge()),
      ],
    );
  }
}

/// Glass pill for titles absent from the library — same language as the
/// request catalog badges.
class _UnavailableBadge extends StatelessWidget {
  const _UnavailableBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        tr('Indispo'),
        style: TextStyle(
          fontSize: AppType.micro,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// "Titres similaires" rail closing a movie/show detail page. Owned entries
/// open their library page, the rest open the request page — the same tap
/// contract as a filmography grid, so the rail is a way out of the library as
/// much as a way around it.
class SimilarTitlesSection extends StatelessWidget {
  final List<CatalogItem> items;

  const SimilarTitlesSection({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return PosterRail(
      title: tr('Titres similaires'),
      itemCount: items.length,
      itemBuilder: (context, index) => CatalogPosterCard(item: items[index]),
    );
  }
}

