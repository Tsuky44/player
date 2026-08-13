import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../../models/models.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/format.dart';
import '../../../widgets/global/media_poster.dart';

const Color _kAccent = AppColors.primary;
const Color _kPanelBg = AppColors.surface;
const double _kEpisodeCardRowHeight = 182.0;

/// Bottom episode browser (Netflix / Emby style) shown while watching a series.
class PlayerEpisodesPanel extends StatefulWidget {
  final String showTitle;
  final int currentEpisodeId;
  final List<Media> seasons;
  final int selectedSeasonId;
  final ValueChanged<int> onSeasonChanged;
  final List<HomeMediaItem> episodes;
  final bool isLoading;
  final VoidCallback onClose;
  final ValueChanged<HomeMediaItem> onEpisodeSelected;

  const PlayerEpisodesPanel({
    super.key,
    required this.showTitle,
    required this.currentEpisodeId,
    required this.seasons,
    required this.selectedSeasonId,
    required this.onSeasonChanged,
    required this.episodes,
    required this.isLoading,
    required this.onClose,
    required this.onEpisodeSelected,
  });

  @override
  State<PlayerEpisodesPanel> createState() => _PlayerEpisodesPanelState();
}

class _PlayerEpisodesPanelState extends State<PlayerEpisodesPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _currentEpisodeKey = GlobalKey();
  bool _didAutoScroll = false;

  @override
  void didUpdateWidget(PlayerEpisodesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isLoading &&
        widget.episodes.isNotEmpty &&
        (oldWidget.isLoading || oldWidget.selectedSeasonId != widget.selectedSeasonId)) {
      _didAutoScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  void _scrollToCurrent() {
    if (_didAutoScroll) return;
    final ctx = _currentEpisodeKey.currentContext;
    if (ctx == null) return;
    _didAutoScroll = true;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.35,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int? _currentIndex() {
    final idx = widget.episodes.indexWhere(
      (e) => e.media.id == widget.currentEpisodeId,
    );
    return idx >= 0 ? idx : null;
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final panelHeight = (screenHeight * 0.52).clamp(320.0, 520.0);
    final currentIdx = _currentIndex();

    return Positioned.fill(
      child: Stack(
        children: [
          GestureDetector(
            onTap: widget.onClose,
            child: Container(color: Colors.black.withValues(alpha: 0.55)),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  height: panelHeight,
                  decoration: BoxDecoration(
                    color: _kPanelBg.withValues(alpha: 0.96),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    border: Border(
                      top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(),
                      if (widget.seasons.length > 1) _buildSeasonSelector(),
                      Expanded(child: _buildBody(currentIdx)),
                    ],
                  ),
                ),
              ),
            ),
          ).animate().slideY(
                begin: 0.12,
                end: 0,
                duration: 280.ms,
                curve: Curves.easeOutCubic,
              ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.showTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Épisodes',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildSeasonSelector() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: widget.seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final season = widget.seasons[index];
          final selected = season.id == widget.selectedSeasonId;
          final label = season.effectiveSeasonNumber != null &&
                  season.effectiveSeasonNumber! > 0
              ? 'Saison ${season.effectiveSeasonNumber}'
              : season.title;

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: selected ? null : () => widget.onSeasonChanged(season.id),
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withValues(alpha: 0.16)
                      : AppColors.surfaceElevated.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.45)
                        : AppColors.glassBorder,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(int? currentIdx) {
    if (widget.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: _kAccent, strokeWidth: 2.5),
      );
    }

    if (widget.episodes.isEmpty) {
      return Center(
        child: Text(
          'Aucun épisode disponible',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        if (currentIdx != null && currentIdx + 1 < widget.episodes.length) ...[
          const _SectionLabel(
            title: 'À suivre',
            subtitle: 'Prochains épisodes de la saison',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _kEpisodeCardRowHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.episodes.length - currentIdx - 1,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, offset) {
                final episode = widget.episodes[currentIdx + 1 + offset];
                final isNext = offset == 0;
                return _EpisodeCard(
                  episode: episode,
                  isCurrent: false,
                  isNext: isNext,
                  onTap: () => widget.onEpisodeSelected(episode),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
        const _SectionLabel(
          title: 'Saison en cours',
          subtitle: 'Tous les épisodes',
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: _kEpisodeCardRowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.episodes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final episode = widget.episodes[index];
              final isCurrent = episode.media.id == widget.currentEpisodeId;
              return _EpisodeCard(
                key: isCurrent ? _currentEpisodeKey : null,
                episode: episode,
                isCurrent: isCurrent,
                isNext: false,
                onTap: () => widget.onEpisodeSelected(episode),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionLabel({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _EpisodeCard extends StatelessWidget {
  final HomeMediaItem episode;
  final bool isCurrent;
  final bool isNext;
  final VoidCallback onTap;

  const _EpisodeCard({
    super.key,
    required this.episode,
    required this.isCurrent,
    required this.isNext,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const cardWidth = 220.0;
    const thumbHeight = 124.0;
    final episodeNum = episode.media.effectiveEpisodeNumber ?? 0;
    final duration = episode.effectiveDuration;
    final isFinished = episode.isFinished;
    final isStarted = episode.currentPositionSeconds > 0 && !isFinished;

    return SizedBox(
      width: cardWidth,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isCurrent
                            ? _kAccent
                            : isNext
                                ? Colors.white.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.08),
                        width: isCurrent ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(isCurrent ? 8 : 9),
                      child: MediaPoster(
                        media: episode.media,
                        width: cardWidth,
                        height: thumbHeight,
                        borderRadius: 0,
                      ),
                    ),
                  ),
                  if (isStarted && !isFinished)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: episode.percentWatched,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        valueColor: const AlwaysStoppedAnimation(_kAccent),
                      ),
                    ),
                  if (isFinished)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  if (episodeNum > 0)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'E$episodeNum',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (isCurrent)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: _Badge(label: 'En cours', color: _kAccent),
                    )
                  else if (isNext)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: _Badge(
                        label: 'Suivant',
                        color: Colors.white.withValues(alpha: 0.85),
                        textColor: Colors.black87,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                episode.media.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent ? Colors.white : Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                  height: 1.25,
                ),
              ),
              if (duration > 0) ...[
                const SizedBox(height: 2),
                Text(
                  formatDuration(duration),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color? textColor;

  const _Badge({
    required this.label,
    required this.color,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor ?? Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
