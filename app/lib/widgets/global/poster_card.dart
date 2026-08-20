import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import 'app_network_image.dart';

/// Single poster card used by every catalog grid (films, séries, bibliothèque,
/// demandes). The poster fills the whole grid cell above the metadata block, so
/// the cell's aspect ratio — not a hardcoded height — decides the poster size.
class PosterCard extends StatefulWidget {
  /// Fully resolved image URL (see `cardPosterUrl`). Null renders the fallback.
  ///
  /// This doubles as the cache identity: two cards showing the same artwork
  /// share one download and one decode, wherever in the app they live.
  final String? posterUrl;
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

  /// Takes the remote's focus as soon as the card is built. One card per screen
  /// sets this — the first poster of the first row — so a television lands on
  /// the content instead of on whatever the traversal policy sorts first.
  final bool autofocus;

  const PosterCard({
    super.key,
    required this.posterUrl,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.overlays = const [],
    this.footerOverlay,
    this.dimmed = false,
    this.showPlayOnHover = false,
    this.placeholderIcon = Icons.movie_outlined,
    this.compact = false,
    this.autofocus = false,
  });

  static const double radius = 12;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;
  bool _focused = false;

  /// Hover and D-pad focus are the same state as far as this card is concerned:
  /// "the user is pointing at me". One flag drives one highlight, so the mouse
  /// and the remote never disagree about which card is live.
  bool get _active => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;

    return TvFocusable(
      onSelect: widget.onTap,
      autofocus: widget.autofocus,
      borderRadius: BorderRadius.circular(PosterCard.radius),
      // The artwork lights up on its own below; a ring around the title lines
      // as well would double the outline.
      showRing: false,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        // The wrapper above owns the focus. Leaving the ink well focusable too
        // would put two stops on every card, so the remote would need two
        // presses to cross one poster.
        canRequestFocus: false,
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
                  if (_active)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(PosterCard.radius),
                        // The remote's highlight has to read across a room, so
                        // it is the accent at full strength rather than the
                        // hairline a mouse pointer gets.
                        border: Border.all(
                          color: _focused
                              ? AppColors.accent
                              : Colors.white.withValues(alpha: 0.16),
                          width: _focused ? 3 : 1,
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
      ),
    );
  }

  Widget _poster() {
    return AppNetworkImage(
      url: widget.posterUrl,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 180),
      color: widget.dimmed ? Colors.black.withValues(alpha: 0.45) : null,
      colorBlendMode: widget.dimmed ? BlendMode.darken : null,
      placeholder: const ColoredBox(color: AppColors.surfaceElevated),
      errorWidget: _fallback(broken: widget.posterUrl?.isNotEmpty ?? false),
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
