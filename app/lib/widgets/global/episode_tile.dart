import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../utils/responsive.dart';
import 'media_poster.dart';
import 'watched_action_button.dart';

class EpisodeTile extends StatefulWidget {
  final HomeMediaItem episode;
  final int episodeNumber;
  final VoidCallback? onTap;
  final Future<void> Function(bool watched)? onToggleWatched;

  const EpisodeTile({
    super.key,
    required this.episode,
    required this.episodeNumber,
    this.onTap,
    this.onToggleWatched,
  });

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _hovered = false;
  bool _updatingWatched = false;

  bool get _isAvailable => widget.episode.isAvailable;

  Future<void> _toggleWatched() async {
    if (!_isAvailable || widget.onToggleWatched == null || _updatingWatched) {
      return;
    }
    setState(() => _updatingWatched = true);
    try {
      await widget.onToggleWatched!(!widget.episode.isFinished);
    } finally {
      if (mounted) setState(() => _updatingWatched = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFinished = widget.episode.isFinished;
    final isStarted = _isAvailable &&
        widget.episode.currentPositionSeconds > 0 &&
        !isFinished;
    final duration = widget.episode.duration > 0
        ? widget.episode.duration
        : widget.episode.media.duration;
    final airDateLabel = formatAirDate(widget.episode.media.releaseDate);

    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final thumbW = compact ? 128.0 : 180.0;
    final thumbH = compact ? 72.0 : 101.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _isAvailable ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.symmetric(
            horizontal: pad,
            vertical: compact ? 12 : 16,
          ),
          color: _hovered && _isAvailable
              ? AppColors.surfaceHover
              : Colors.transparent,
          child: Opacity(
            opacity: _isAvailable ? 1 : 0.72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  SizedBox(
                    width: 36,
                    child: Column(
                      children: [
                        const SizedBox(height: 40),
                        if (!_isAvailable)
                          const Icon(Icons.event_available_outlined,
                              color: AppColors.textMuted, size: 22)
                        else if (isFinished)
                          const Icon(Icons.check_circle_rounded,
                              color: AppColors.success, size: 22)
                        else if (_hovered)
                          const Icon(Icons.play_circle_fill_rounded,
                              color: AppColors.textPrimary, size: 28)
                        else
                          Text(
                            '${widget.episodeNumber}',
                            style: TextStyle(
                              color: isStarted
                                  ? AppColors.textPrimary
                                  : AppColors.textMuted,
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Stack(
                  children: [
                    ColorFiltered(
                      colorFilter: _isAvailable
                          ? const ColorFilter.mode(
                              Colors.transparent, BlendMode.dst)
                          : ColorFilter.mode(
                              Colors.black.withValues(alpha: 0.35),
                              BlendMode.darken,
                            ),
                      child: MediaPoster(
                        media: widget.episode.media,
                        width: thumbW,
                        height: thumbH,
                        borderRadius: 6,
                      ),
                    ),
                    if (!_isAvailable)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Indispo',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    if (isStarted && !isFinished)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(6)),
                          child: LinearProgressIndicator(
                            value: widget.episode.percentWatched,
                            minHeight: 3,
                            backgroundColor: AppColors.border,
                            valueColor: const AlwaysStoppedAnimation(
                                AppColors.progress),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(width: compact ? 12 : 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              compact
                                  ? 'E${widget.episodeNumber} · ${widget.episode.media.title}'
                                  : widget.episode.media.title,
                              style: TextStyle(
                                color: _isAvailable
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                                fontWeight: FontWeight.w600,
                                fontSize: compact ? 14 : 16,
                              ),
                            ),
                          ),
                          if (_isAvailable && duration > 0 && !compact)
                            Text(
                              formatDuration(duration),
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          if (_isAvailable && widget.onToggleWatched != null)
                            WatchedActionButton(
                              compact: true,
                              isWatched: isFinished,
                              isLoading: _updatingWatched,
                              onPressed: _toggleWatched,
                            ),
                        ],
                      ),
                      if (compact && _isAvailable && duration > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          formatDuration(duration),
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (widget.episode.media.overview != null &&
                          widget.episode.media.overview!.isNotEmpty &&
                          !compact) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.episode.media.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                      if (!_isAvailable) ...[
                        const SizedBox(height: 6),
                        Text(
                          airDateLabel ?? 'Pas sur le serveur',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ] else if (isFinished)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'Vu',
                            style: TextStyle(
                              color: AppColors.success,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else if (isStarted)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '${(widget.episode.percentWatched * 100).round()}% visionné',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
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
