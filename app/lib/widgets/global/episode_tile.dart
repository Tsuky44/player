import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import '../../utils/format.dart';
import '../../utils/responsive.dart';
import 'media_download_button.dart';
import 'media_poster.dart';
import 'share_media_button.dart';
import 'watched_action_button.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

class EpisodeTile extends StatefulWidget {
  final HomeMediaItem episode;
  final int episodeNumber;
  final VoidCallback? onTap;
  final Future<void> Function(bool watched)? onToggleWatched;

  /// Contexte de la série, transmis au bouton de téléchargement.
  ///
  /// Un épisode ne porte pas le nom de sa série, et une fois hors ligne il n'y
  /// a plus personne à qui le demander : c'est ici, au moment du geste, qu'il
  /// faut le capturer.
  final String? showTitle;
  final int? showId;
  final String? showPosterUrl;
  final int? seasonNumber;

  /// Faux sur la page d'un lien de partage : son visiteur regarde, il
  /// n'emporte rien (ADR-0037 §9).
  final bool allowDownload;

  const EpisodeTile({
    super.key,
    required this.episode,
    required this.episodeNumber,
    this.onTap,
    this.onToggleWatched,
    this.showTitle,
    this.showId,
    this.showPosterUrl,
    this.seasonNumber,
    this.allowDownload = true,
  });

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _hovered = false;
  bool _focused = false;
  bool _updatingWatched = false;

  /// Pointer hover and D-pad focus drive the same row highlight.
  bool get _active => _hovered || _focused;

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
    // Un épisode indisponible dit déjà sa date dans sa ligne d'état.
    final releaseDay = _isAvailable
        ? formatReleaseDay(widget.episode.media.releaseDate)
        : null;
    final compactMeta = [
      if (_isAvailable && duration > 0) formatDuration(duration),
      if (releaseDay != null) releaseDay,
    ].join(' · ');

    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final thumbW = compact ? 128.0 : 180.0;
    final thumbH = compact ? 72.0 : 101.0;

    return TvFocusable(
      // An episode that has not aired is shown but not reachable: the remote
      // skips straight over it instead of landing on a dead row.
      enabled: _isAvailable && widget.onTap != null,
      onSelect: widget.onTap,
      // A full-width row grows into its neighbours if it scales, and a list of
      // episodes is scanned top to bottom, so it reads better near the top of
      // the viewport than dead centre.
      focusScale: 1.0,
      scrollAlignment: 0.3,
      showRing: false,
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      child: MouseRegion(
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
            decoration: BoxDecoration(
              color: _active && _isAvailable
                  ? AppColors.surfaceHover
                  : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: _focused ? AppColors.accent : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
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
                            const Icon(AppIcons.airDate,
                                color: AppColors.textMuted, size: 22)
                          else if (isFinished)
                            // Discret : le bouton à droite dit déjà « vu », en
                            // clair. Trois coches vertes par ligne (ici, à
                            // droite, et un « Vu » sous le titre) faisaient de
                            // la liste un tableau de validation.
                            const Icon(AppIcons.check,
                                color: AppColors.textMuted, size: 20)
                          else if (_active)
                            const Icon(AppIcons.playCircleFilled,
                                color: AppColors.textPrimary, size: 28)
                          else
                            Text(
                              '${widget.episodeNumber}',
                              style: TextStyle(
                                color: isStarted
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted,
                                fontSize: AppType.title2,
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
                          borderRadius: 10,
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
                            child: Text(
                              tr('Indispo'),
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: AppType.caption,
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
                                bottom: Radius.circular(10)),
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
                                  fontSize: AppType.subhead,
                                ),
                              ),
                            if (_isAvailable && widget.allowDownload)
                              MediaDownloadButton(
                                item: widget.episode,
                                compact: true,
                                showTitle: widget.showTitle,
                                showId: widget.showId,
                                showPosterUrl: widget.showPosterUrl,
                                seasonNumber: widget.seasonNumber,
                              ),
                            if (_isAvailable)
                              ShareMediaButton(
                                item: widget.episode,
                                compact: true,
                                title: widget.showTitle == null
                                    ? null
                                    : '${widget.showTitle} · ${widget.episode.media.title}',
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
                        if (compact && compactMeta.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            compactMeta,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: AppType.footnote,
                            ),
                          ),
                        ],
                        if (!compact && releaseDay != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            releaseDay,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: AppType.subhead,
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
                              fontSize: AppType.subhead,
                              height: 1.45,
                            ),
                          ),
                        ],
                        if (!_isAvailable) ...[
                          const SizedBox(height: 6),
                          Text(
                            airDateLabel ?? tr('Pas sur le serveur'),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: AppType.footnote,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ] else if (isStarted && !isFinished)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              formatRemaining(widget.episode.effectiveDuration -
                                      widget.episode.currentPositionSeconds) ??
                                  '',
                              style: const TextStyle(
                                color: AppColors.textMuted,
                                fontSize: AppType.footnote,
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
      ),
    );
  }
}
