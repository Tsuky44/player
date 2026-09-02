import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../playback/playback_session.dart';

import '../../../models/models.dart';
import '../../../utils/app_platform.dart';
import '../hooks/use_episode_navigation.dart';
import '../hooks/use_player_controller.dart';
import 'chapters_debug_panel.dart';
import 'player_settings_ui.dart';
import 'player_subtitles_picker.dart';

/// Bottom-sheet widget that lets the user pick audio / subtitle tracks,
/// switch the video display mode (fit vs cover), and select transcoding quality.
class PlayerSettingsSheet extends StatefulWidget {
  final PlaybackSession session;
  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;
  final VoidCallback? onClose;
  final PlayerController? playerController;
  final EpisodeNavigationController? episodeNav;
  final Future<void> Function(int absoluteSeconds)? onSeekToAbsolute;

  /// Opens on this tab index (0 audio, 1 subs, 2 quality, 3 display, 4 chapters).
  final int initialTabIndex;

  const PlayerSettingsSheet({
    super.key,
    required this.session,
    required this.currentFit,
    required this.onFitChanged,
    this.onClose,
    this.playerController,
    this.episodeNav,
    this.onSeekToAbsolute,
    this.initialTabIndex = 0,
  });

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  late BoxFit _fit;
  int _tabIndex = 0;
  StreamSubscription<void>? _tracksSubscription;

  static const _tabs = [
    PlayerSettingsTab(icon: Icons.audiotrack_rounded, label: 'Audio'),
    PlayerSettingsTab(icon: Icons.subtitles_outlined, label: 'Sous-titres'),
    PlayerSettingsTab(icon: Icons.hd_rounded, label: 'Qualité'),
    PlayerSettingsTab(icon: Icons.aspect_ratio_rounded, label: 'Affichage'),
  ];

  static const _tabsWithChapters = [
    PlayerSettingsTab(icon: Icons.audiotrack_rounded, label: 'Audio'),
    PlayerSettingsTab(icon: Icons.subtitles_outlined, label: 'Sous-titres'),
    PlayerSettingsTab(icon: Icons.hd_rounded, label: 'Qualité'),
    PlayerSettingsTab(icon: Icons.aspect_ratio_rounded, label: 'Affichage'),
    PlayerSettingsTab(icon: Icons.list_alt_rounded, label: 'Chapitres'),
  ];

  @override
  void initState() {
    super.initState();
    _fit = widget.currentFit;
    _tabIndex = widget.initialTabIndex;
    _tracksSubscription = widget.playerController?.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tracksSubscription?.cancel();
    super.dispose();
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  String _audioTrackName(PlaybackTrack track, int index) {
    if (track.id == 'no') return 'Désactivé';
    return track.title ??
        (track.language != null ? 'Audio (${track.language})' : 'Audio ${index + 1}');
  }

  String _subtitleTrackName(PlaybackTrack track, int index) {
    if (track.id == 'no') return 'Désactivés';
    return track.title ??
        (track.language != null
            ? 'Sous-titre (${track.language})'
            : 'Sous-titre ${index + 1}');
  }

  bool get _hasChaptersTab =>
      widget.episodeNav != null &&
      widget.onSeekToAbsolute != null &&
      widget.playerController != null;

  List<PlayerSettingsTab> get _activeTabs =>
      _hasChaptersTab ? _tabsWithChapters : _tabs;

  double get _panelWidth => _hasChaptersTab ? 400 : 380;

  double get _panelHeight => _hasChaptersTab ? 520 : 480;

  @override
  Widget build(BuildContext context) {

    final currentAudio = widget.session.currentAudioTrack;
    final currentSubtitle = widget.session.currentSubtitleTrack;
    final controller = widget.playerController;
    final mediaTracks = controller?.mediaTracks;

    return PlayerSettingsShell(
      width: _panelWidth,
      maxHeight: _panelHeight,
      onClose: _close,
      tabs: _activeTabs,
      selectedTab: _tabIndex.clamp(0, _activeTabs.length - 1),
      onTabSelected: (i) => setState(() => _tabIndex = i),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: IndexedStack(
          index: _tabIndex.clamp(0, _activeTabs.length - 1),
          children: [
            // Audio
            (controller != null && mediaTracks != null && mediaTracks.audio.isNotEmpty)
                ? _buildCanonicalAudioList(mediaTracks.audio, controller)
                : _buildTrackList(
                    widget.session.audioTracks,
                    currentAudio,
                    (track) => _audioTrackName(track, widget.session.audioTracks.indexOf(track)),
                    (track) => widget.session.setAudioTrack(track),
                  ),
            // Subtitles
            (controller != null && mediaTracks != null)
                ? PlayerSubtitlesPicker(
                    session: widget.session,
                    playerController: controller,
                    onSelected: _close,
                  )
                : _buildTrackList(
                    widget.session.subtitleTracks,
                    currentSubtitle,
                    (track) =>
                        _subtitleTrackName(track, widget.session.subtitleTracks.indexOf(track)),
                    (track) => widget.session.setSubtitles(
                        SubtitleSelection.track(track)),
                  ),
            _buildQualityOptions(),
            _buildDisplayOptions(),
            if (_hasChaptersTab)
              ChaptersDebugPanel(
                episodeNav: widget.episodeNav!,
                playerController: widget.playerController!,
                onSeekToAbsolute: widget.onSeekToAbsolute!,
              ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 220.ms, curve: Curves.easeOut)
        .scaleXY(begin: 0.96, end: 1, duration: 220.ms, curve: Curves.easeOutCubic);
  }

  Widget _buildTrackList<T>(
    List<T> tracks,
    T? currentTrack,
    String Function(T) getName,
    void Function(T) onSelect,
  ) {
    if (tracks.isEmpty) {
      return const _EmptyTracksMessage();
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final isSelected = track == currentTrack;
        final name = getName(track);
        final (title, subtitle) = splitTrackLabel(name);

        return PlayerSettingsTrackRow(
          label: title,
          subtitle: subtitle,
          selected: isSelected,
          onTap: () {
            onSelect(track);
            _close();
          },
        );
      },
    );
  }

  Widget _buildDisplayOptions() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      children: [
        PlayerSettingsChoiceCard(
          icon: Icons.fit_screen_rounded,
          label: 'Original',
          subtitle: 'Conserve les proportions, bandes noires possibles',
          selected: _fit == BoxFit.contain,
          onTap: () {
            setState(() => _fit = BoxFit.contain);
            widget.onFitChanged(BoxFit.contain);
          },
        ),
        PlayerSettingsChoiceCard(
          icon: Icons.crop_free_rounded,
          label: 'Adaptatif',
          subtitle: "Remplit l'écran, coupe les bords",
          selected: _fit == BoxFit.cover,
          onTap: () {
            setState(() => _fit = BoxFit.cover);
            widget.onFitChanged(BoxFit.cover);
          },
        ),
      ],
    );
  }

  Widget _buildQualityOptions() {
    final controller = widget.playerController;
    final currentQuality = controller?.currentQuality;

    // Direct Play is native-only: it hands the player the file itself, which a
    // browser cannot open. Listing it on the web would offer a mode that plays
    // the picture without any sound and says nothing about why.
    final qualities = <(String, String?, IconData, String)>[
      if (!AppPlatform.isWeb)
        (
          'Direct',
          null,
          Icons.bolt_rounded,
          'Lecture directe, aucune transcodation'
        ),
      ('360p', '360p', Icons.sd_rounded, '640×360 — faible consommation'),
      ('480p', '480p', Icons.sd_rounded, '854×480 — qualité standard'),
      ('720p', '720p', Icons.hd_rounded, '1280×720 — HD'),
      ('1080p', '1080p', Icons.hd_outlined, '1920×1080 — Full HD'),
      ('4K', '2160p', Icons.four_k_rounded, '3840×2160 — débit réduit (~8 Mb/s)'),
    ];

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: qualities.length,
      itemBuilder: (context, index) {
        final (label, quality, icon, subtitle) = qualities[index];
        final isSelected = currentQuality == quality;

        return PlayerSettingsChoiceCard(
          icon: icon,
          label: label,
          subtitle: subtitle,
          selected: isSelected,
          onTap: () {
            if (controller == null) return;
            _close();
            if (quality == null) {
              controller.switchToDirectPlay();
            } else {
              controller.switchToQuality(quality);
            }
          },
        );
      },
    );
  }

  Widget _buildCanonicalAudioList(
    List<MediaAudioTrack> audioTracks,
    PlayerController controller,
  ) {
    if (audioTracks.isEmpty) {
      return const _EmptyTracksMessage();
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: audioTracks.length,
      itemBuilder: (context, index) {
        final track = audioTracks[index];
        final isSelected = index == controller.selectedAudioIndex;
        final (title, subtitle) = splitTrackLabel(track.displayName);

        return PlayerSettingsTrackRow(
          label: title,
          subtitle: subtitle,
          selected: isSelected,
          onTap: () {
            if (!isSelected) controller.switchAudioTrack(index);
            _close();
          },
        );
      },
    );
  }
}

class _EmptyTracksMessage extends StatelessWidget {
  const _EmptyTracksMessage();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Aucune piste disponible',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 13,
          fontFamily: 'Manrope',
        ),
      ),
    );
  }
}
