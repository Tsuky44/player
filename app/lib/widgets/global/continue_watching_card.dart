import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import 'media_poster.dart';

class ContinueWatchingCard extends StatefulWidget {
  /// TMDB posters are 2:3 — match that ratio so faces/titles aren't cropped.
  static const cardWidth = 176.0;
  static const posterHeight = cardWidth * 1.5;
  static const rowHeight = posterHeight + 6 + 40; // poster + gap + 2 text lines

  final HomeMediaItem item;
  final VoidCallback onTap;
  final VoidCallback? onTitleTap;

  const ContinueWatchingCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onTitleTap,
  });

  @override
  State<ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<ContinueWatchingCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    const width = ContinueWatchingCard.cardWidth;
    const height = ContinueWatchingCard.posterHeight;
    final progress = widget.item.percentWatched;
    final detail = _detailLine();

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: widget.onTap,
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: MediaPoster(
                        media: widget.item.media,
                        posterUrlOverride: widget.item.displayPosterUrl,
                        width: width,
                        height: height,
                        borderRadius: 0,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                      ),
                    ),
                    if (_hovered)
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: Colors.black.withValues(alpha: 0.4),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 52,
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(6),
                        ),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.01, 1.0),
                          minHeight: 4,
                          backgroundColor: AppColors.border,
                          valueColor: const AlwaysStoppedAnimation(AppColors.progress),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            MouseRegion(
              cursor: widget.onTitleTap != null
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              child: GestureDetector(
                onTap: widget.onTitleTap,
                behavior: HitTestBehavior.opaque,
                child: Text(
                  widget.item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    height: 1.2,
                  ),
                ),
              ),
            ),
              if (detail != null)
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
    );
  }

  String? _detailLine() {
    final remaining =
        widget.item.effectiveDuration - widget.item.currentPositionSeconds;
    final remainingStr =
        remaining > 0 ? '${formatDuration(remaining)} restantes' : null;

    if (widget.item.media.type == MediaType.episode) {
      final parts = <String>[];
      final epInfo = widget.item.continueWatchingSubtitle;
      if (epInfo != null) parts.add(epInfo);
      if (remainingStr != null) parts.add(remainingStr);
      return parts.isEmpty ? null : parts.join(' · ');
    }

    return remainingStr;
  }
}
