import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../navigation/detail_prefetch.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import 'app_network_image.dart';
import 'detail_metadata.dart';
import '../../tv/tv_focus_memory.dart';
import 'media_logo_display.dart';
import 'poster_card.dart';
import 'overlay_back_button.dart';

/// Hero header for movie/show detail pages: a wide backdrop with
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

  /// Badges techniques du fichier (« 4K », « Dolby Atmos »), après la ligne
  /// de métadonnées. Voir [techBadgesFor].
  final List<String> badges;

  /// True while [details] is still on its way. The backdrop then holds a flat
  /// surface instead of borrowing the poster: stretching a portrait poster to
  /// 1280 px cost a download of its own and was swapped for the real backdrop
  /// a moment later — a second image and a visible flash for nothing.
  final bool loading;

  const DetailBackdropHeader({
    super.key,
    required this.fallback,
    required this.details,
    required this.metadata,
    required this.onBack,
    this.actions,
    this.badges = const [],
    this.loading = false,
  });

  static const double heightDesktop = 540;

  /// Le synopsis de l'en-tête : sa police, sa largeur et son nombre de lignes
  /// servent aussi à [overviewTruncated], qui décide si la fiche le répète en
  /// entier plus bas.
  static const TextStyle overviewStyle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 14,
    height: 1.55,
  );
  static const double overviewMaxWidth = 720;
  static int overviewMaxLines(BuildContext context) =>
      AppLayout.isCompact(context) ? 4 : 3;

  /// Vrai quand [overview] ne tient pas dans l'en-tête et y est coupé.
  ///
  /// La fiche répétait jusqu'ici le synopsis en entier sous l'en-tête,
  /// toujours — deux fois le même paragraphe, l'un sous l'autre, dès qu'il
  /// était court.
  static bool overviewTruncated(BuildContext context, String overview) {
    final screen = MediaQuery.sizeOf(context).width;
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final available = compact
        ? screen - 2 * pad
        : (screen - 2 * pad - posterWidth - 36).clamp(0.0, overviewMaxWidth);
    final painter = TextPainter(
      // La police vient du thème, comme pour le Text de l'en-tête : mesuré
      // dans la police par défaut, le synopsis n'a pas la même largeur.
      text: TextSpan(
        text: overview,
        style: DefaultTextStyle.of(context).style.merge(overviewStyle),
      ),
      maxLines: overviewMaxLines(context),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: available);
    final truncated = painter.didExceedMaxLines;
    painter.dispose();
    return truncated;
  }

  static const double posterWidth = 190;
  static const double posterHeight = 285;

  /// What the backdrop slot draws: the catalog backdrop, else — once we know
  /// there is none — the poster.
  static String? _backdropSource(
    MediaDetails? details,
    Media fallback, {
    required bool loading,
  }) {
    final backdrop = details?.backdropUrl;
    if (backdrop != null && backdrop.isNotEmpty) return backdrop;
    if (details == null && loading) return null;
    return fallback.posterUrl;
  }

  /// Warms every image the header — and the cast row right under it — draws,
  /// at the exact sizes they are drawn at, so a page opened from a hovered or
  /// focused card paints complete on its first frame.
  ///
  /// Sizes mirror [build], [_Poster] and [CastSection]; a mismatch only costs
  /// the head start, never correctness.
  static Future<void> precacheArtwork({
    required MediaDetails details,
    required Media fallback,
    required String? baseUrl,
    required Size screenSize,
    required double devicePixelRatio,
    required bool compact,
    int castCount = 8,
  }) {
    final dpr = devicePixelRatio;
    return Future.wait([
      AppNetworkImage.precache(
        backdropImageUrl(
          _backdropSource(details, fallback, loading: false),
          serverBaseUrl: baseUrl,
        ),
        devicePixelRatio: dpr,
        decodeWidth: screenSize.width,
      ),
      AppNetworkImage.precache(
        logoImageUrl(details.logoUrl, serverBaseUrl: baseUrl),
        devicePixelRatio: dpr,
      ),
      if (!compact)
        AppNetworkImage.precache(
          detailPosterUrl(
            details.posterUrl ?? fallback.posterUrl,
            serverBaseUrl: baseUrl,
          ),
          devicePixelRatio: dpr,
          decodeWidth: posterWidth,
        ),
      for (final member in details.cast.take(castCount))
        AppNetworkImage.precache(
          castProfileUrl(member.profileUrl),
          devicePixelRatio: dpr,
          decodeWidth: CastSection.cardWidth(compact),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final baseUrl = apiClient.baseUrl;
    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final screenH = MediaQuery.sizeOf(context).height;
    final headerHeight =
        compact ? (screenH * 0.62).clamp(420.0, 520.0) : heightDesktop;

    final posterUrl = detailPosterUrl(
      details?.posterUrl ?? fallback.posterUrl,
      serverBaseUrl: baseUrl,
    );
    final backdropUrl = backdropImageUrl(
      _backdropSource(details, fallback, loading: loading),
      serverBaseUrl: baseUrl,
    );

    final title = details?.title ?? fallback.title;
    final tagline = details?.tagline;
    final overview = details?.overview ?? fallback.overview;

    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Même surtitre que le bandeau de l'accueil : en capitales espacées,
        // gris — l'accent bleu reste au focus et à la progression.
        Text(
          mediaTypeLabel(fallback.type).toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 11,
            letterSpacing: 1.6,
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
        if (metadata.isNotEmpty || badges.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < metadata.length; i++) ...[
                if (i > 0) const MetadataDot(),
                metadata[i],
              ],
              if (badges.isNotEmpty) ...[
                if (metadata.isNotEmpty) const SizedBox(width: 4),
                for (final badge in badges) TechBadge(badge),
              ],
            ],
          ),
        ],
        if (overview != null && overview.isNotEmpty) ...[
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: compact ? double.infinity : overviewMaxWidth),
            child: Text(
              overview,
              maxLines: overviewMaxLines(context),
              overflow: TextOverflow.ellipsis,
              style: overviewStyle,
            ),
          ),
        ],
        if (actions != null && !compact) ...[
          const SizedBox(height: 22),
          actions!,
        ],
      ],
    );

    final header = SizedBox(
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

    if (actions == null || !compact) return header;
    // Sur téléphone, les actions passent sous l'image plutôt que dessus : le
    // titre, le logo, les puces et quatre lignes de synopsis remplissent déjà
    // l'en-tête, et un bouton pleine largeur de plus le faisait remonter
    // jusque sous le bouton retour.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
          child: actions,
        ),
      ],
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;

  const _Poster({required this.url});

  @override
  Widget build(BuildContext context) {
    const w = DetailBackdropHeader.posterWidth;
    const h = DetailBackdropHeader.posterHeight;
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
            child: const Icon(Icons.movie_rounded,
                size: 48, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Horizontal, scrollable cast row ("Têtes d'affiche"). Tapping an actor opens
/// their profile page via [onTapMember].
class CastSection extends StatelessWidget {
  final List<CastMember> cast;
  final void Function(CastMember member)? onTapMember;

  const CastSection({super.key, required this.cast, this.onTapMember});

  static double cardWidth(bool compact) => compact ? 96.0 : 120.0;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();
    final pad = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final cardW = cardWidth(compact);
    final cardH = compact ? 120.0 : 150.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 16),
          child: Text(
            "Têtes d'affiche",
            style: detailSectionTitleStyle(context),
          ),
        ),
        // La rangée se souvient de la personne sur laquelle la télécommande
        // était — voir [TvFocusMemory].
        TvFocusMemory(
          child: SizedBox(
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
                onTap: onTapMember == null
                    ? null
                    : () => onTapMember!(cast[index]),
              ),
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
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated
                                .withValues(alpha: 0.9),
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
          padding:
              EdgeInsets.fromLTRB(pad, 8, pad, 16 - PosterCard.liftHeadroom),
          child: Text(
            'Titres similaires',
            style: detailSectionTitleStyle(context),
          ),
        ),
        // Même mémoire que les rangées de l'accueil — voir [TvFocusMemory].
        TvFocusMemory(
          child: SizedBox(
            // The cards size themselves from the cell, so the rail states the
            // height a poster + two metadata lines need at this width.
            height: mediaCardHeight(cardWidth) + PosterCard.liftHeadroom,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  EdgeInsets.fromLTRB(pad, PosterCard.liftHeadroom, pad, 0),
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
      child: const Icon(Icons.person_rounded,
          size: 40, color: AppColors.textMuted),
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
          if (overview == null || overview.isEmpty)
            Text(
              emptyOverviewLabel,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 15),
            )
          else if (DetailBackdropHeader.overviewTruncated(
              context, overview)) ...[
            Text('Synopsis', style: detailSectionTitleStyle(context)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Text(
                overview,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
            ),
          ],
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
