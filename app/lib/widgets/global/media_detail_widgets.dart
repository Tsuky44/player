import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import 'app_network_image.dart';
import 'hero_banner.dart' show MetadataChip;
import 'media_logo_display.dart';
import 'poster_card.dart';
import 'overlay_back_button.dart';

/// Emby-style hero header for movie/show detail pages: a wide backdrop with
/// gradients, an overlaid poster, title, tagline, metadata chips and actions.
///
/// [details] is the live catalog payload (may be null while loading); [fallback]
/// is the local library record used for instant display before it arrives.
class DetailBackdropHeader extends StatelessWidget {
  final Media fallback;
  final MediaDetails? details;
  final List<Widget> metadata;
  final Widget? actions;
  final VoidCallback onBack;

  const DetailBackdropHeader({
    super.key,
    required this.fallback,
    required this.details,
    required this.metadata,
    required this.onBack,
    this.actions,
  });

  static const double heightDesktop = 540;

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final baseUrl = apiClient.baseUrl;
    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final screenH = MediaQuery.sizeOf(context).height;
    final headerHeight = compact
        ? (screenH * 0.62).clamp(420.0, 520.0)
        : heightDesktop;

    final posterUrl = detailPosterUrl(
      details?.posterUrl ?? fallback.posterUrl,
      serverBaseUrl: baseUrl,
    );
    final backdropUrl = backdropImageUrl(
      details?.backdropUrl != null && details!.backdropUrl!.isNotEmpty
          ? details!.backdropUrl
          : fallback.posterUrl,
      serverBaseUrl: baseUrl,
    );

    final title = details?.title ?? fallback.title;
    final tagline = details?.tagline;
    final overview = details?.overview ?? fallback.overview;

    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          mediaTypeLabel(fallback.type),
          style: const TextStyle(
            color: AppColors.accentMuted,
            fontWeight: FontWeight.w600,
            fontSize: 12,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 8),
        MediaLogoDisplay(
          title: title,
          logoUrl: logoImageUrl(details?.logoUrl, serverBaseUrl: baseUrl),
          maxHeight: compact ? 72 : 160,
          maxWidth: compact ? double.infinity : 420,
          textStyle: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                height: 1.05,
                fontSize: compact ? 26 : null,
              ),
        ),
        if (tagline != null && tagline.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            tagline,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        if (metadata.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metadata,
          ),
        ],
        if (overview != null && overview.isNotEmpty) ...[
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? double.infinity : 720),
            child: Text(
              overview,
              maxLines: compact ? 4 : 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.55,
              ),
            ),
          ),
        ],
        if (actions != null) ...[
          const SizedBox(height: 22),
          actions!,
        ],
      ],
    );

    return SizedBox(
      height: headerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Decoded at window width, not at the source's 1280 px: the backdrop
          // is the largest image on the page and the one that used to hold up
          // the first paint.
          AppNetworkImage(
            url: backdropUrl,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            filterQuality: FilterQuality.high,
            decodeWidth: MediaQuery.sizeOf(context).width,
            fadeInDuration: const Duration(milliseconds: 220),
            placeholder: const ColoredBox(color: AppColors.surfaceElevated),
            errorWidget: const ColoredBox(color: AppColors.surfaceElevated),
          ),

          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  AppColors.background,
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          if (!compact)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    AppColors.background.withValues(alpha: 0.95),
                    AppColors.background.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 0.85],
                ),
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.25),
                    AppColors.background.withValues(alpha: 0.75),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),

          Positioned(
            left: pad,
            right: pad,
            bottom: compact ? 20 : 36,
            child: compact
                ? infoColumn
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Poster(url: posterUrl),
                      const SizedBox(width: 36),
                      Expanded(child: infoColumn),
                    ],
                  ),
          ),

          Positioned(
            top: 4,
            left: 8,
            child: OverlayBackButton(onPressed: onBack),
          ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;

  const _Poster({required this.url});

  @override
  Widget build(BuildContext context) {
    const w = 190.0;
    const h = 285.0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AppNetworkImage(
          url: url,
          width: w,
          height: h,
          fit: BoxFit.cover,
          errorWidget: Container(
            width: w,
            height: h,
            color: AppColors.surfaceElevated,
            child: const Icon(Icons.movie_rounded, size: 48, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// A gold star rating badge (TMDB vote average out of 10).
class RatingBadge extends StatelessWidget {
  final double rating;

  const RatingBadge({super.key, required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: Color(0xFFF5C518), size: 16),
          const SizedBox(width: 4),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small colored pill used for genres.
class GenrePill extends StatelessWidget {
  final String label;

  const GenrePill({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Builds the metadata chip list (year, runtime, rating, type) shared by the
/// movie and show hero headers.
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
  final chips = <Widget>[];
  if (year != null) chips.add(MetadataChip(label: year));

  if (type == MediaType.show) {
    if (seasons > 0) {
      chips.add(MetadataChip(label: '$seasons saison${seasons > 1 ? 's' : ''}'));
    }
  } else {
    final seconds = runtimeMinutes > 0 ? runtimeMinutes * 60 : durationSeconds;
    if (seconds > 0) chips.add(MetadataChip(label: formatDuration(seconds)));
  }

  if (rating > 0) chips.add(RatingBadge(rating: rating));
  if (statusLabel != null && statusLabel.isNotEmpty) {
    chips.add(MetadataChip(label: statusLabel));
  }
  return chips;
}

/// Horizontal, scrollable cast row ("Têtes d'affiche"). Tapping an actor opens
/// their profile page via [onTapMember].
class CastSection extends StatelessWidget {
  final List<CastMember> cast;
  final void Function(CastMember member)? onTapMember;

  const CastSection({super.key, required this.cast, this.onTapMember});

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final cardW = compact ? 96.0 : 120.0;
    final cardH = compact ? 120.0 : 150.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 16),
          child: Text(
            "Têtes d'affiche",
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        SizedBox(
          height: compact ? 178 : 214,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad),
            itemCount: cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) => _CastCard(
              member: cast[index],
              width: cardW,
              imageHeight: cardH,
              onTap: onTapMember == null ? null : () => onTapMember!(cast[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastCard extends StatelessWidget {
  final CastMember member;
  final VoidCallback? onTap;
  final double width;
  final double imageHeight;

  const _CastCard({
    required this.member,
    this.onTap,
    this.width = 120,
    this.imageHeight = 150,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      // A cast card with no destination is decoration; the remote skips it.
      enabled: onTap != null,
      onSelect: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
      width: width,
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AppNetworkImage(
                  // The catalog serves h632 portraits — ~6x the pixels a card
                  // this size can show, fetched a dozen at a time.
                  url: castProfileUrl(member.profileUrl),
                  width: width,
                  height: imageHeight,
                  fit: BoxFit.cover,
                  errorWidget: const _CastPlaceholder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                member.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (member.character != null && member.character!.isNotEmpty)
                Text(
                  member.character!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

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
                      const Icon(Icons.collections_bookmark_rounded,
                          color: AppColors.accent, size: 26),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'FAIT PARTIE DE LA SAGA',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 11,
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
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Text(
                            'Voir la saga',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right_rounded,
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
class CatalogPosterCard extends StatelessWidget {
  final CatalogItem item;
  final VoidCallback onTap;

  const CatalogPosterCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final character = item.character;
    final year = item.year;
    // Filmography cards lead with the role; everywhere else, the request
    // catalog's "année • ★ note" line.
    final subtitle = character != null && character.isNotEmpty
        ? character
        : [
            if (year != null && year.isNotEmpty) year,
            if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}',
          ].join('  •  ');

    return PosterCard(
      posterUrl: cardPosterUrl(item.posterUrl),
      title: item.title,
      subtitle: subtitle,
      onTap: onTap,
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
        'Indispo',
        style: TextStyle(
          fontSize: 10,
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
  final void Function(CatalogItem item) onTapItem;

  const SimilarTitlesSection({
    super.key,
    required this.items,
    required this.onTapItem,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final cardWidth = compact ? 112.0 : 142.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 16),
          child: Text(
            'Titres similaires',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        SizedBox(
          // The cards size themselves from the cell, so the rail states the
          // height a poster + two metadata lines need at this width.
          height: mediaCardHeight(cardWidth),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) => SizedBox(
              width: cardWidth,
              child: CatalogPosterCard(
                item: items[index],
                onTap: () => onTapItem(items[index]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CastPlaceholder extends StatelessWidget {
  const _CastPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceElevated,
      alignment: Alignment.center,
      child: const Icon(Icons.person_rounded, size: 40, color: AppColors.textMuted),
    );
  }
}

/// Synopsis + facts (genres, director, writers, studios) block.
class DetailInfoSection extends StatelessWidget {
  final MediaDetails? details;
  final String? fallbackOverview;
  final String emptyOverviewLabel;

  const DetailInfoSection({
    super.key,
    required this.details,
    this.fallbackOverview,
    this.emptyOverviewLabel = 'Synopsis indisponible.',
  });

  @override
  Widget build(BuildContext context) {
    final overview = details?.overview ?? fallbackOverview;
    final genres = details?.genres ?? const <String>[];
    final director = details?.director;
    final writers = details?.writers ?? const <String>[];
    final studios = details?.studios ?? const <String>[];

    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 28, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (genres.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final g in genres) GenrePill(label: g)],
            ),
            const SizedBox(height: 24),
          ],
          Text(
            'Synopsis',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            overview != null && overview.isNotEmpty ? overview : emptyOverviewLabel,
            style: TextStyle(
              color: overview != null && overview.isNotEmpty
                  ? AppColors.textSecondary
                  : AppColors.textMuted,
              fontSize: 15,
              height: 1.6,
            ),
          ),
          if (director != null && director.isNotEmpty ||
              writers.isNotEmpty ||
              studios.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(
              spacing: compact ? 24 : 48,
              runSpacing: 16,
              children: [
                if (director != null && director.isNotEmpty)
                  _FactColumn(label: 'Réalisation', values: [director]),
                if (writers.isNotEmpty)
                  _FactColumn(label: 'Scénario', values: writers),
                if (studios.isNotEmpty)
                  _FactColumn(label: 'Studios', values: studios),
              ],
            ),
          ],
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
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          values.join(', '),
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
