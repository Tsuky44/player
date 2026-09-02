import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../playback/playback_session.dart';

import '../../../../models/models.dart';
import '../../../../tv/tv_focus.dart';
import '../../../../tv/tv_mode.dart';
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

  /// Where the remote lands on the list currently shown: the value already in
  /// force inside a section, the row it came back from on the index.
  ///
  /// One node moved from row to row on every section change, rather than an
  /// `autofocus` on each: two rows claiming the entry point is a ring that
  /// jumps.
  final FocusNode _entryNode = FocusNode(debugLabel: 'emby-menu-entry');

  /// The section just left, so the index puts the ring back on its row instead
  /// of dropping the user at the top of the list.
  EmbyMenuSection? _returnedFrom;

  PlayerController? get _controller => widget.playerController;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _fit = widget.currentFit;
    _tracksSubscription = _controller?.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
    _focusEntryAfterBuild();
  }

  @override
  void dispose() {
    _tracksSubscription?.cancel();
    _entryNode.dispose();
    super.dispose();
  }

  // --- Remote navigation ---------------------------------------------------

  /// Puts the remote on the entry point of the list now showing.
  ///
  /// After the frame: the list has just been replaced, and [_entryNode] is
  /// attached to a row only once that row is built. Waiting is also what makes
  /// this choice win over the popup's generic "focus the first thing you find"
  /// — on a track list the ring belongs on the language being played, not on
  /// whatever happens to be at the top.
  void _focusEntryAfterBuild() {
    // Off a television nobody asked for the focus, and taking it would paint a
    // ring neither the pointer nor a finger called for.
    if (!TvMode.isTv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entryNode.requestFocus();
    });
  }

  void _openSection(EmbyMenuSection section) {
    setState(() => _section = section);
    _focusEntryAfterBuild();
  }

  void _backToRoot() {
    setState(() {
      _returnedFrom = _section;
      _section = EmbyMenuSection.root;
    });
    _focusEntryAfterBuild();
  }

  /// The index row the remote lands on.
  EmbyMenuSection get _rootEntry =>
      _returnedFrom ??
      (_hasQuality ? EmbyMenuSection.quality : EmbyMenuSection.audio);

  /// Back and left go up one level instead of closing everything.
  ///
  /// The menu shows a hierarchy — an index, a section — and the remote has to
  /// be able to climb it the same way it came down. On the index the key is
  /// left alone: it reaches the popup, which closes the menu, and that is the
  /// right next step up.
  KeyEventResult _handleMenuKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_section == EmbyMenuSection.root) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.arrowLeft) {
      _backToRoot();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    return Focus(
      // Never a destination itself: this node is here only to see the keys
      // travelling up from the focused row.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleMenuKey,
      child: Material(
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
          // Height follows the visible section, so leaving a 12-chapter list
          // for "Affichage" shrinks the menu instead of leaving a hole.
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
      ),
    );
  }

  Widget _buildRoot() {
    Widget row(EmbyMenuSection section, String label, String value) {
      return _EmbyMenuRow(
        label: label,
        value: value,
        focusNode: _rootEntry == section ? _entryNode : null,
        onTap: () => _openSection(section),
      );
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (_hasQuality)
          row(EmbyMenuSection.quality, 'Qualité', _qualityValue),
        row(EmbyMenuSection.audio, 'Audio', _audioValue),
        row(EmbyMenuSection.subtitles, 'Sous-titres', _subtitlesValue),
        row(EmbyMenuSection.speed, 'Vitesse de lecture', _speedValue),
        row(EmbyMenuSection.display, 'Affichage', _displayValue),
        if (_hasChapters)
          row(
            EmbyMenuSection.chapters,
            'Chapitres',
            '${widget.episodeNav!.chapters.length}',
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
        _EmbyMenuBackHeader(title: title, onBack: _backToRoot),
        Flexible(child: body),
      ],
    );
  }

  /// Lays out a section and decides which of its rows the remote arrives on.
  ///
  /// The option already in force, so opening "Audio" outlines the language
  /// being played and the next press moves from there. A list with nothing
  /// selected — the chapters — hands it to the first row.
  Widget _sectionList(List<_EmbyMenuOption> options) {
    final selected = options.indexWhere((option) => option.selected);
    final entry = selected < 0 ? 0 : selected;

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 6),
      children: [
        for (var i = 0; i < options.length; i++)
          options[i].withFocusNode(i == entry ? _entryNode : null),
      ],
    );
  }

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
        onTap: () => _setFit(BoxFit.contain),
      ),
      _EmbyMenuOption(
        label: 'Adaptatif',
        subtitle: "Remplit l'écran, coupe les bords",
        selected: _fit == BoxFit.cover,
        onTap: () => _setFit(BoxFit.cover),
      ),
    ]);
  }

  /// The one section that stays open after a choice, so the ring has to follow
  /// it: the entry node has just moved to the other row, and without this the
  /// focus would be left on a row that no longer holds it.
  void _setFit(BoxFit fit) {
    setState(() => _fit = fit);
    widget.onFitChanged(fit);
    _focusEntryAfterBuild();
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

/// What makes a row reachable by a remote, and — the whole point — visible.
///
/// These rows used to be [InkWell]s. A remote could already walk them: the
/// arrows moved the focus exactly as they should. What it could not do is
/// *show* it. An ink highlight is painted by the enclosing [Material], which
/// here sits above the panel's own opaque background — so every ring, splash
/// and hover tint landed underneath it and never reached the screen. A menu
/// where nothing lights up is a menu a remote cannot be driven through, and it
/// reads from the sofa as an app that has stopped answering.
///
/// So the focus is drawn here instead, over the row: the accent ring
/// [TvFocusable] paints everywhere else in the app, plus a fill that carries
/// from three metres away. The pointer gets its own, quieter tint — it had
/// lost its hover state to the same burial.
class _EmbyMenuTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  /// Supplied for the one row the remote is sent to on arrival.
  final FocusNode? focusNode;

  const _EmbyMenuTile({
    required this.child,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_EmbyMenuTile> createState() => _EmbyMenuTileState();
}

class _EmbyMenuTileState extends State<_EmbyMenuTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      onSelect: widget.onTap,
      borderRadius: BorderRadius.circular(6),
      // Rows touch each other: growing one would climb over its neighbour.
      focusScale: 1.0,
      // A long list — twelve chapters — reads better with the outlined row
      // near the top than pinned to the middle.
      scrollAlignment: 0.3,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // Read from the tree rather than kept in a flag of our own: the menu
          // hands one node from row to row as it changes section, so a row can
          // be built around a node that already holds the focus — and nothing
          // would ever announce a change that never happened.
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: focused
                      ? _focusFill
                      : _hovered
                          ? _hoverFill
                          : Colors.transparent,
                ),
                child: widget.child,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Reads from three metres away, on a surface that is already almost black.
final Color _focusFill = Colors.white.withValues(alpha: 0.14);

/// The pointer gets the quieter half of the same treatment.
final Color _hoverFill = Colors.white.withValues(alpha: 0.07);

/// Index row: what the setting is on, without opening it.
class _EmbyMenuRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const _EmbyMenuRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return _EmbyMenuTile(
      onTap: onTap,
      focusNode: focusNode,
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
  final FocusNode? focusNode;

  const _EmbyMenuOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.value,
    this.badge,
    this.focusNode,
  });

  /// The entry node is placed by the list, which is the only thing that knows
  /// which option is the current one — the sections build their rows without
  /// looking at each other.
  _EmbyMenuOption withFocusNode(FocusNode? node) => _EmbyMenuOption(
        label: label,
        selected: selected,
        onTap: onTap,
        subtitle: subtitle,
        value: value,
        badge: badge,
        focusNode: node,
      );

  @override
  Widget build(BuildContext context) {
    return _EmbyMenuTile(
      onTap: onTap,
      focusNode: focusNode,
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
    return _EmbyMenuTile(
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
