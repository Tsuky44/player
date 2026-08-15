import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/app_network_image.dart';

/// Emby-style "Info" card: poster, title, episode line, duration/CC badge,
/// technical stream line, and a restart-from-beginning action.
class PlayerInfoSheet extends StatelessWidget {
  final Media media;

  /// Show/movie title only (no season/episode suffix) — the bold line.
  final String showTitle;

  /// Pre-composed episode/release line (season/episode code + episode title +
  /// release tag) — same string as the episodeTitleBlock control's muted
  /// line, so both read identically. Composed by the caller because only it
  /// knows whether [media] came from a [HomeMediaItem] (episode title).
  final String episodeInfoLine;

  final MediaTracks? tracks;
  final Duration? duration;
  final VoidCallback onRestart;
  final VoidCallback? onClose;

  const PlayerInfoSheet({
    super.key,
    required this.media,
    required this.showTitle,
    required this.episodeInfoLine,
    required this.tracks,
    required this.duration,
    required this.onRestart,
    this.onClose,
  });

  void _close(BuildContext context) {
    if (onClose != null) {
      onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  String get _durationLabel {
    final d = duration;
    if (d == null || d.inMinutes <= 0) return '';
    return '${d.inMinutes}m';
  }

  String get _technicalLine {
    final parts = <String>[];
    final video = tracks?.video;
    if (video != null && video.displayName.isNotEmpty) {
      parts.add(video.displayName);
    }
    final defaultAudio = (tracks?.audio ?? const <MediaAudioTrack>[])
        .cast<MediaAudioTrack?>()
        .firstWhere((t) => t!.isDefault, orElse: () => null) ??
        (tracks?.audio.isNotEmpty == true ? tracks!.audio.first : null);
    if (defaultAudio != null) parts.add(defaultAudio.displayName);
    return parts.join('   ');
  }

  bool get _hasSubtitles => (tracks?.subtitles.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);

    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.94),
            borderRadius: radius,
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AppNetworkImage(
                  url: cardPosterUrl(media.posterUrl),
                  width: 90,
                  height: 130,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            showTitle,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        _RestartButton(onPressed: onRestart),
                        _CloseButton(onPressed: () => _close(context)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      episodeInfoLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        if (_durationLabel.isNotEmpty) ...[
                          Text(
                            _durationLabel,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_hasSubtitles) const _Badge(label: 'CC'),
                      ],
                    ),
                    if (_technicalLine.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _technicalLine,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 220.ms, curve: Curves.easeOut)
        .scaleXY(begin: 0.96, end: 1, duration: 220.ms, curve: Curves.easeOutCubic);
  }
}

class _Badge extends StatelessWidget {
  final String label;

  const _Badge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RestartButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _RestartButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
                SizedBox(width: 4),
                Text(
                  'Depuis le début',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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

class _CloseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.close_rounded, color: AppColors.textSecondary, size: 18),
          ),
        ),
      ),
    );
  }
}
