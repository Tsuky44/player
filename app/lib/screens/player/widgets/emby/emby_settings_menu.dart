import 'dart:async';

import 'package:flutter/material.dart';
import '../../playback/playback_session.dart';

import '../../../../models/models.dart';
import '../../../../utils/app_platform.dart';
import '../../hooks/use_episode_navigation.dart';
import '../../hooks/use_player_controller.dart';
import '../player_settings_ui.dart' show splitTrackLabel;
import 'emby_chrome_theme.dart';

/// Which list the menu is showing. [root] is the index of sections.
enum EmbyMenuSection { root, quality, audio, subtitles, speed, display, chapters }

/// Emby-shaped settings menu: a narrow list of sections, each drilling into a
/// list of choices, instead of a tall tabbed panel.
///
/// The tabbed [PlayerSettingsSheet] shows every category's chrome at once —
/// header, subtitle, five segmented tabs — before showing a single option. On
/// the Emby chrome that reads as a dialog dropped on the video. Emby instead
/// puts one column of rows over the picture: what each setting is *currently*
/// on is visible without opening anything, and a category costs one tap.
///
/// Like the rest of this chrome, the look is locked and ignores
/// [PlayerLayoutConfig] — see [EmbyChromeTheme].
class EmbySettingsMenu extends StatefulWidget {
  final PlaybackSession session;
  final PlayerController? playerController;
  final EpisodeNavigationController? episodeNav;

  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;

  final double playbackRate;
  final List<double> playbackRates;
  final ValueChanged<double> onRateChanged;

  final Future<void> Function(int absoluteSeconds)? onSeekToAbsolute;

  /// Opening straight on a category — the CC and audio buttons of the chrome
  /// point at their own list rather than at the index.
  final EmbyMenuSection initialSection;

  final VoidCallback onClose;

  const EmbySettingsMenu({
    super.key,
    required this.session,
    required this.currentFit,
    required this.onFitChanged,
    required this.playbackRate,
    required this.playbackRates,
    required this.onRateChanged,
    required this.onClose,
    this.playerController,
    this.episodeNav,
    this.onSeekToAbsolute,
    this.initialSection = EmbyMenuSection.root,
  });

  static const double width = 292;
  static const double maxHeight = 420;

  @override
  State<EmbySettingsMenu> createState() => _EmbySettingsMenuState();
}

class _EmbySettingsMenuState extends State<EmbySettingsMenu> {
  late EmbyMenuSection _section;
  late BoxFit _fit;
  StreamSubscription<void>? _tracksSubscription;

  PlayerController? get _controller => widget.playerController;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _fit = widget.currentFit;
    _tracksSubscription = _controller?.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tracksSubscription?.cancel();
    super.dispose();
  }

  // --- Section availability ------------------------------------------------

  bool get _hasChapters =>
      widget.episodeNav != null &&
      widget.episodeNav!.chapters.isNotEmpty &&
      widget.onSeekToAbsolute != null;

  bool get _hasQuality => _controller != null;

  // --- Current-value summaries shown on the root rows ----------------------

  String get _qualityValue {
    final quality = _controller?.currentQuality;
    if (quality == null) return 'Direct';
    return quality == '2160p' ? '4K' : quality;
  }

  String get _audioValue {
    final controller = _controller;
    final tracks = controller?.mediaTracks?.audio;
    if (controller != null && tracks != null && tracks.isNotEmpty) {
      final index = controller.selectedAudioIndex;
      if (index >= 0 && index < tracks.length) {
        return splitTrackLabel(tracks[index].displayName).$1;
      }
      return '—';
    }
    final current = widget.session.currentAudioTrack;
    if (current == null || current.id == 'no') return 'Désactivé';
    return current.title ?? current.language ?? 'Piste 1';
  }

  String get _subtitlesValue {
    final controller = _controller;
    if (controller == null) return '—';

    if (controller.currentQuality == null) {
      final current = widget.session.currentSubtitleTrack;
      if (current == null || current.id == 'no') return 'Désactivés';
      return current.title ?? current.language ?? 'Piste 1';
    }

    final lang = controller.selectedSubtitleLang;
    if (lang == null) return 'Désactivés';
    final track = controller.mediaTracks?.subtitles
        .where((s) => s.lang == lang)
        .firstOrNull;
    return track == null ? lang : splitTrackLabel(track.displayName).$1;
  }

  String get _speedValue =>
      widget.playbackRate == 1.0 ? 'Normale' : '${_trimRate(widget.playbackRate)}×';

  String get _displayValue => _fit == BoxFit.cover ? 'Adaptatif' : 'Original';

  static String _trimRate(double rate) {
    final text = rate.toStringAsFixed(2);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _timecode(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: EmbySettingsMenu.width,
        decoration: BoxDecoration(
          // Flat surface, no blur: this chrome renders no glass anywhere.
          color: EmbyChromeTheme.tooltipSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        // Height follows the visible section, so leaving a 12-chapter list for
        // "Affichage" shrinks the menu instead of leaving a hole.
        child: AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: EmbySettingsMenu.maxHeight,
            ),
            child: _section == EmbyMenuSection.root
                ? _buildRoot()
                : _buildSection(),
          ),
        ),
      ),
    );
  }

  Widget _buildRoot() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (_hasQuality)
          _EmbyMenuRow(
            label: 'Qualité',
            value: _qualityValue,
            onTap: () => setState(() => _section = EmbyMenuSection.quality),
          ),
        _EmbyMenuRow(
          label: 'Audio',
          value: _audioValue,
          onTap: () => setState(() => _section = EmbyMenuSection.audio),
        ),
        _EmbyMenuRow(
          label: 'Sous-titres',
          value: _subtitlesValue,
          onTap: () => setState(() => _section = EmbyMenuSection.subtitles),
        ),
        _EmbyMenuRow(
          label: 'Vitesse de lecture',
          value: _speedValue,
          onTap: () => setState(() => _section = EmbyMenuSection.speed),
        ),
        _EmbyMenuRow(
          label: 'Affichage',
          value: _displayValue,
          onTap: () => setState(() => _section = EmbyMenuSection.display),
        ),
        if (_hasChapters)
          _EmbyMenuRow(
            label: 'Chapitres',
            value: '${widget.episodeNav!.chapters.length}',
            onTap: () => setState(() => _section = EmbyMenuSection.chapters),
          ),
      ],
    );
  }

  Widget _buildSection() {
    final (title, body) = switch (_section) {
      EmbyMenuSection.quality => ('Qualité', _buildQuality()),
      EmbyMenuSection.audio => ('Audio', _buildAudio()),
      EmbyMenuSection.subtitles => ('Sous-titres', _buildSubtitles()),
      EmbyMenuSection.speed => ('Vitesse de lecture', _buildSpeed()),
      EmbyMenuSection.display => ('Affichage', _buildDisplay()),
      EmbyMenuSection.chapters => ('Chapitres', _buildChapters()),
      EmbyMenuSection.root => ('', const SizedBox.shrink()),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _EmbyMenuBackHeader(
          title: title,
          onBack: () => setState(() => _section = EmbyMenuSection.root),
        ),
        Flexible(child: body),
      ],
    );
  }

  Widget _sectionList(List<Widget> children) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 6),
        children: children,
      );

  // --- Sections ------------------------------------------------------------

  Widget _buildQuality() {
    final controller = _controller;
    if (controller == null) return const _EmbyMenuEmpty();

    // Direct Play is native-only: it hands the player the file itself, which a
    // browser cannot open.
    final qualities = <(String, String?)>[
      if (!AppPlatform.isWeb) ('Direct', null),
      ('360p', '360p'),
      ('480p', '480p'),
      ('720p', '720p'),
      ('1080p', '1080p'),
      ('4K', '2160p'),
    ];

    return _sectionList([
      for (final (label, quality) in qualities)
        _EmbyMenuOption(
          label: label,
          selected: controller.currentQuality == quality,
          onTap: () {
            widget.onClose();
            if (quality == null) {
              controller.switchToDirectPlay();
            } else {
              controller.switchToQuality(quality);
            }
          },
        ),
    ]);
  }

  Widget _buildAudio() {
    final controller = _controller;
    final tracks = controller?.mediaTracks?.audio;

    if (controller != null && tracks != null && tracks.isNotEmpty) {
      return _sectionList([
        for (var i = 0; i < tracks.length; i++)
          () {
            final (title, subtitle) = splitTrackLabel(tracks[i].displayName);
            final selected = i == controller.selectedAudioIndex;
            return _EmbyMenuOption(
              label: title,
              subtitle: subtitle,
              selected: selected,
              onTap: () {
                if (!selected) controller.switchAudioTrack(i);
                widget.onClose();
              },
            );
          }(),
      ]);
    }

    final internal = widget.session.audioTracks;
    if (internal.isEmpty) return const _EmbyMenuEmpty();
    final current = widget.session.currentAudioTrack;

    return _sectionList([
      for (var i = 0; i < internal.length; i++)
        _EmbyMenuOption(
          label: internal[i].id == 'no'
              ? 'Désactivé'
              : internal[i].title ??
                  (internal[i].language != null
                      ? 'Audio (${internal[i].language})'
                      : 'Audio ${i + 1}'),
          selected: internal[i] == current,
          onTap: () {
            widget.session.setAudioTrack(internal[i]);
            widget.onClose();
          },
        ),
    ]);
  }

  Widget _buildSubtitles() {
    final controller = _controller;
    if (controller == null) return const _EmbyMenuEmpty();

    // Direct Play reads the tracks off the file; a transcode carries the
    // canonical list from the server. Same split as [PlayerSubtitlesPicker].
    if (controller.currentQuality == null) {
      final subs = widget.session.subtitleTracks
          .where((t) => t.id != 'auto')
          .toList();
      if (subs.isEmpty) return const _EmbyMenuEmpty();
      final current = widget.session.currentSubtitleTrack;

      return _sectionList([
        for (var i = 0; i < subs.length; i++)
          _EmbyMenuOption(
            label: subs[i].id == 'no'
                ? 'Désactivés'
                : subs[i].title ??
                    (subs[i].language != null
                        ? 'Sous-titre (${subs[i].language})'
                        : 'Sous-titre ${i + 1}'),
            selected: subs[i] == current,
            onTap: () {
              controller.selectInternalSubtitle(subs[i]);
              widget.onClose();
            },
          ),
      ]);
    }

    final subtitles = controller.mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    return _sectionList([
      _EmbyMenuOption(
        label: 'Désactivés',
        selected: controller.selectedSubtitleLang == null,
        onTap: () {
          controller.setSubtitle(null);
          widget.onClose();
        },
      ),
      for (final track in subtitles)
        () {
          final (title, subtitle) = splitTrackLabel(track.displayName);
          return _EmbyMenuOption(
            label: title,
            subtitle: subtitle,
            // A bitmap track has to be burned into the video while
            // transcoding, so picking it costs a short reload.
            badge: !track.ready
                ? '…'
                : (track.image ? 'image' : null),
            selected: controller.selectedSubtitleLang == track.lang,
            onTap: () {
              controller.setSubtitle(track.lang);
              widget.onClose();
            },
          );
        }(),
    ]);
  }

  Widget _buildSpeed() {
    return _sectionList([
      for (final rate in widget.playbackRates)
        _EmbyMenuOption(
          label: rate == 1.0 ? 'Normale' : '${_trimRate(rate)}×',
          selected: rate == widget.playbackRate,
          onTap: () {
            widget.onRateChanged(rate);
            widget.onClose();
          },
        ),
    ]);
  }

  Widget _buildDisplay() {
    return _sectionList([
      _EmbyMenuOption(
        label: 'Original',
        subtitle: 'Conserve les proportions',
        selected: _fit == BoxFit.contain,
        onTap: () {
          setState(() => _fit = BoxFit.contain);
          widget.onFitChanged(BoxFit.contain);
        },
      ),
      _EmbyMenuOption(
        label: 'Adaptatif',
        subtitle: "Remplit l'écran, coupe les bords",
        selected: _fit == BoxFit.cover,
        onTap: () {
          setState(() => _fit = BoxFit.cover);
          widget.onFitChanged(BoxFit.cover);
        },
      ),
    ]);
  }

  Widget _buildChapters() {
    final chapters = widget.episodeNav!.chapters;
    final seek = widget.onSeekToAbsolute!;

    return _sectionList([
      for (final chapter in chapters)
        _EmbyMenuOption(
          label: chapter.title.isEmpty ? 'Chapitre ${chapter.id}' : chapter.title,
          value: _timecode(chapter.startTime),
          selected: false,
          onTap: () {
            widget.onClose();
            seek(chapter.startTime.round());
          },
        ),
    ]);
  }
}

// --- Rows ------------------------------------------------------------------

/// Index row: what the setting is on, without opening it.
class _EmbyMenuRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _EmbyMenuRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: EmbyChromeTheme.title,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: EmbyChromeTheme.meta,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: EmbyChromeTheme.meta,
            ),
          ],
        ),
      ),
    );
  }
}

/// Choice row: a check occupies the left slot whether or not it is set, so the
/// labels stay on one vertical line.
class _EmbyMenuOption extends StatelessWidget {
  final String label;
  final String? subtitle;
  final String? value;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _EmbyMenuOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.value,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: selected
                  ? const Icon(Icons.check_rounded,
                      size: 17, color: EmbyChromeTheme.title)
                  : null,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: EmbyChromeTheme.title,
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 6),
                        _EmbyMenuBadge(text: badge!),
                      ],
                    ],
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: EmbyChromeTheme.meta,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              Text(
                value!,
                style: const TextStyle(
                  color: EmbyChromeTheme.meta,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmbyMenuBackHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _EmbyMenuBackHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onBack,
      child: Container(
        height: 44,
        padding: const EdgeInsets.only(left: 8, right: 16),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0x1AFFFFFF)),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.chevron_left_rounded,
                size: 22, color: EmbyChromeTheme.title),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(
                color: EmbyChromeTheme.title,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmbyMenuBadge extends StatelessWidget {
  final String text;

  const _EmbyMenuBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: const TextStyle(color: EmbyChromeTheme.meta, fontSize: 10),
      ),
    );
  }
}

class _EmbyMenuEmpty extends StatelessWidget {
  const _EmbyMenuEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      child: Text(
        'Aucune piste disponible',
        style: TextStyle(color: EmbyChromeTheme.meta, fontSize: 13),
      ),
    );
  }
}
