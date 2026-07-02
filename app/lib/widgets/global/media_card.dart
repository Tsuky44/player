import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import 'media_poster.dart';

class MediaCard extends StatefulWidget {
  final Media media;
  final double? progress;
  final VoidCallback onTap;
  final bool compact;

  const MediaCard({
    super.key,
    required this.media,
    this.progress,
    required this.onTap,
    this.compact = false,
  });

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 150.0;
        final posterRatio = widget.compact ? 1.45 : 1.5;
        final height = width * posterRatio;
        final year = widget.compact ? null : extractYear(widget.media.releaseDate);

        return MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      MediaPoster(
                        media: widget.media,
                        width: width,
                        height: height,
                      ),
                      if (_hovered)
                        Container(
                          color: Colors.black.withValues(alpha: 0.35),
                          child: Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              color: Colors.white,
                              size: widget.compact ? 40 : 48,
                            ),
                          ),
                        ),
                      if (widget.progress != null &&
                          widget.progress! > 0 &&
                          widget.progress! < 0.99)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: widget.progress,
                            minHeight: 3,
                            backgroundColor: AppColors.border,
                            valueColor: const AlwaysStoppedAnimation(AppColors.progress),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.media.title,
                  maxLines: widget.compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: widget.compact ? 12 : 13,
                    height: 1.2,
                  ),
                ),
                if (year != null)
                  Text(
                    year,
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
        );
      },
    );
  }
}
