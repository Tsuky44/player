import 'dart:async';
import 'package:flutter/material.dart';
import '../../../models/models.dart';
import '../../../utils/format.dart';
import '../hooks/use_episode_navigation.dart';
import '../hooks/use_player_controller.dart';

/// Debug panel listing MKV chapters and DB intro/outro markers for an episode.
class ChaptersDebugPanel extends StatefulWidget {
  final EpisodeNavigationController episodeNav;
  final PlayerController playerController;
  final Future<void> Function(int absoluteSeconds) onSeekToAbsolute;

  const ChaptersDebugPanel({
    super.key,
    required this.episodeNav,
    required this.playerController,
    required this.onSeekToAbsolute,
  });

  @override
  State<ChaptersDebugPanel> createState() => _ChaptersDebugPanelState();
}

class _ChaptersDebugPanelState extends State<ChaptersDebugPanel> {
  StreamSubscription? _positionSub;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.episodeNav.addListener(_rebuild);
    _positionSub = widget.playerController.session.positions.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.episodeNav.removeListener(_rebuild);
    _positionSub?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  int get _absolutePosition {
    final pos = widget.playerController.session.position.inSeconds;
    final offset = widget.playerController.hlsStartOffset;
    return widget.playerController.currentQuality != null && offset > 0
        ? pos + offset
        : pos;
  }

  int get _durationSeconds => widget.playerController.duration.inSeconds;

  Future<void> _refreshChapters() async {
    setState(() => _refreshing = true);
    try {
      await widget.episodeNav.refreshChapters();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = widget.episodeNav;
    final ts = nav.timestamps;
    final pos = _absolutePosition;
    final duration = _durationSeconds;
    final plausibleIntro =
        ts?.isPlausibleIntro(mediaDurationSeconds: duration > 0 ? duration : null) ??
            false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(
          position: pos,
          duration: duration,
          skipSource: nav.activeSkipSource,
          showSkipIntro: nav.showSkipIntro,
          skipTarget: nav.introSkipTarget,
          timestamps: ts,
          plausibleIntro: plausibleIntro,
          onRefresh: _refreshing ? null : _refreshChapters,
          refreshing: _refreshing,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: nav.chapters.isEmpty
              ? Center(
                  child: Text(
                    nav.isLoading
                        ? 'Chargement…'
                        : 'Aucun chapitre MKV détecté',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 12,
                      fontFamily: 'Manrope',
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: nav.chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = nav.chapters[index];
                    final isIntro = nav.isIntroChapter(chapter);
                    final isOutro = nav.isOutroChapter(chapter);
                    final isCurrent = nav.isInsideChapter(chapter, pos);
                    return _ChapterRow(
                      index: index,
                      chapter: chapter,
                      isIntro: isIntro,
                      isOutro: isOutro,
                      isCurrent: isCurrent,
                      onTap: () => widget.onSeekToAbsolute(chapter.startTime.floor()),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Text(
            'Appuyez sur un chapitre pour seek à son début.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.35),
              fontSize: 10,
              fontFamily: 'Manrope',
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int position;
  final int duration;
  final String skipSource;
  final bool showSkipIntro;
  final int skipTarget;
  final EpisodeTimestamps? timestamps;
  final bool plausibleIntro;
  final VoidCallback? onRefresh;
  final bool refreshing;

  const _SummaryCard({
    required this.position,
    required this.duration,
    required this.skipSource,
    required this.showSkipIntro,
    required this.skipTarget,
    required this.timestamps,
    required this.plausibleIntro,
    this.onRefresh,
    required this.refreshing,
  });

  @override
  Widget build(BuildContext context) {
    final ts = timestamps;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Position ${formatPlaybackTime(position)}'
                '${duration > 0 ? ' / ${formatPlaybackTime(duration)}' : ''}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Manrope',
                ),
              ),
              const Spacer(),
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  icon: refreshing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.refresh,
                          size: 16,
                          color: Colors.white.withOpacity(0.6),
                        ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Recharger les chapitres',
                ),
            ],
          ),
          const SizedBox(height: 6),
          _InfoLine(label: 'Source skip', value: skipSource),
          _InfoLine(
            label: 'Bouton skip',
            value: showSkipIntro
                ? 'Visible → ${formatPlaybackTime(skipTarget)}'
                : 'Masqué',
          ),
          if (ts != null) ...[
            const Divider(height: 14, color: Colors.white12),
            _InfoLine(
              label: 'Intro DB',
              value: ts.hasIntro
                  ? '${formatPlaybackTime(ts.introStart)} → ${formatPlaybackTime(ts.introEnd)}'
                  : '—',
              trailing: ts.hasIntro
                  ? (plausibleIntro ? 'OK' : 'Rejeté')
                  : null,
              trailingColor: plausibleIntro ? Colors.greenAccent : Colors.orangeAccent,
            ),
            _InfoLine(
              label: 'Outro DB',
              value: ts.hasOutro
                  ? '${formatPlaybackTime(ts.outroStart)} → ${formatPlaybackTime(ts.outroEnd)}'
                  : '—',
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  final String? trailing;
  final Color? trailingColor;

  const _InfoLine({
    required this.label,
    required this.value,
    this.trailing,
    this.trailingColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 11,
                fontFamily: 'Manrope',
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 11,
                fontFamily: 'Manrope',
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: TextStyle(
                color: trailingColor ?? Colors.white54,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                fontFamily: 'Manrope',
              ),
            ),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  final int index;
  final VideoChapter chapter;
  final bool isIntro;
  final bool isOutro;
  final bool isCurrent;
  final VoidCallback onTap;

  const _ChapterRow({
    required this.index,
    required this.chapter,
    required this.isIntro,
    required this.isOutro,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = chapter.startTime.floor();
    final end = chapter.endTime.ceil();
    final title = chapter.title.isEmpty ? 'Sans titre' : chapter.title;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: isCurrent
                ? Colors.white.withOpacity(0.12)
                : Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isCurrent
                  ? const Color(0xFF0A84FF).withOpacity(0.4)
                  : Colors.white.withOpacity(0.06),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '#$index',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.35),
                  fontSize: 10,
                  fontFamily: 'Geist',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Manrope',
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatPlaybackTime(start)} → ${formatPlaybackTime(end)}',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 10,
                        fontFamily: 'Geist',
                      ),
                    ),
                  ],
                ),
              ),
              if (isIntro) _Badge('INTRO', const Color(0xFF0A84FF)),
              if (isOutro) _Badge('OUTRO', Colors.orangeAccent),
              if (isCurrent) _Badge('ACTUEL', Colors.greenAccent),
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

  const _Badge(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w700,
          fontFamily: 'Geist',
        ),
      ),
    );
  }
}
