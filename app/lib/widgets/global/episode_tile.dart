import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import 'media_poster.dart';
import 'watched_action_button.dart';

class EpisodeTile extends StatefulWidget {
  final HomeMediaItem episode;
  final int episodeNumber;
  final VoidCallback onTap;
  final Future<void> Function(bool watched)? onToggleWatched;

  const EpisodeTile({
    super.key,
    required this.episode,
    required this.episodeNumber,
    required this.onTap,
    this.onToggleWatched,
  });

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _hovered = false;
  bool _updatingWatched = false;

  Future<void> _toggleWatched() async {
    if (widget.onToggleWatched == null || _updatingWatched) return;
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
    final isStarted = widget.episode.currentPositionSeconds > 0 && !isFinished;
    final duration = widget.episode.duration > 0
        ? widget.episode.duration
        : widget.episode.media.duration;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          color: _hovered ? AppColors.surfaceHover : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    if (isFinished)
                      const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 22)
                    else if (_hovered)
                      const Icon(Icons.play_circle_fill_rounded, color: AppColors.textPrimary, size: 28)
                    else
                      Text(
                        '${widget.episodeNumber}',
                        style: TextStyle(
                          color: isStarted ? AppColors.textPrimary : AppColors.textMuted,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Stack(
                children: [
                  MediaPoster(
                    media: widget.episode.media,
                    width: 180,
                    height: 101,
                    borderRadius: 6,
                  ),
                  if (isStarted && !isFinished)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                        child: LinearProgressIndicator(
                          value: widget.episode.percentWatched,
                          minHeight: 3,
                          backgroundColor: AppColors.border,
                          valueColor: const AlwaysStoppedAnimation(AppColors.progress),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.episode.media.title,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (duration > 0)
                          Text(
                            formatDuration(duration),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        if (widget.onToggleWatched != null)
                          WatchedActionButton(
                            compact: true,
                            isWatched: isFinished,
                            isLoading: _updatingWatched,
                            onPressed: _toggleWatched,
                          ),
                      ],
                    ),
                    if (widget.episode.media.overview != null &&
                        widget.episode.media.overview!.isNotEmpty) ...[
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
                    if (isFinished)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Vu',
                          style: TextStyle(color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      )
                    else if (isStarted)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${(widget.episode.percentWatched * 100).round()}% visionné',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
