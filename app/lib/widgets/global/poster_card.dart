import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// Single poster card used by every catalog grid (films, séries, bibliothèque,
/// demandes). The poster fills the whole grid cell above the metadata block, so
/// the cell's aspect ratio — not a hardcoded height — decides the poster size.
class PosterCard extends StatefulWidget {
  /// Fully resolved image URL (see `cardPosterUrl`). Null renders the fallback.
  final String? posterUrl;
  final String? cacheKey;
  final String title;

  /// Secondary line (année · note · rôle…). Rendered even when empty so every
  /// card in a grid keeps the same baseline.
  final String? subtitle;
  final VoidCallback onTap;

  /// Badges / dots stacked over the poster (already `Positioned`).
  final List<Widget> overlays;

  /// Full-width overlay pinned to the bottom of the poster (progression…).
  final Widget? footerOverlay;

  /// Dims the poster for titles absent from the library.
  final bool dimmed;

  /// Play affordance revealed on hover — only for playable local content.
  final bool showPlayOnHover;
  final IconData placeholderIcon;
  final bool compact;

  const PosterCard({
    super.key,
    required this.posterUrl,
    required this.title,
    required this.onTap,
    this.cacheKey,
    this.subtitle,
    this.overlays = const [],
    this.footerOverlay,
    this.dimmed = false,
    this.showPlayOnHover = false,
    this.placeholderIcon = Icons.movie_outlined,
    this.compact = false,
  });

  static const double radius = 12;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(PosterCard.radius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(PosterCard.radius),
                    child: _poster(),
                  ),
                  if (_hovered)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(PosterCard.radius),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                          width: 1,
                        ),
                        color: widget.showPlayOnHover
                            ? Colors.black.withValues(alpha: 0.22)
                            : null,
                      ),
                      child: widget.showPlayOnHover
                          ? Center(
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white.withValues(alpha: 0.95),
                                size: compact ? 36 : 42,
                              ),
                            )
                          : null,
                    ),
                  ...widget.overlays,
                  if (widget.footerOverlay != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(PosterCard.radius),
                        ),
                        child: widget.footerOverlay!,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: compact ? 7 : 9),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 13 : 14,
                fontWeight: FontWeight.w600,
                height: 1.2,
                letterSpacing: -0.1,
                color: widget.dimmed
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              widget.subtitle ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 11 : 12,
                height: 1.2,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _poster() {
    final url = widget.posterUrl;
    if (url == null || url.isEmpty) return _fallback();

    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: widget.cacheKey,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      color: widget.dimmed ? Colors.black.withValues(alpha: 0.45) : null,
      colorBlendMode: widget.dimmed ? BlendMode.darken : null,
      placeholder: (_, __) => const ColoredBox(color: AppColors.surfaceElevated),
      errorWidget: (_, __, ___) => _fallback(broken: true),
    );
  }

  Widget _fallback({bool broken = false}) {
    return ColoredBox(
      color: AppColors.surfaceElevated,
      child: Center(
        child: Icon(
          broken ? Icons.broken_image_outlined : widget.placeholderIcon,
          color: AppColors.textMuted,
          size: 42,
        ),
      ),
    );
  }
}
