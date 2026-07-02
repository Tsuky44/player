import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../../models/models.dart';
import '../hooks/use_episode_navigation.dart';
import '../hooks/use_player_controller.dart';
import 'chapters_debug_panel.dart';
import 'player_settings_ui.dart';

class SettingsMenu extends StatefulWidget {
  final mk.Player player;
  final VoidCallback onClose;
  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;
  final PlayerController? playerController;
  final EpisodeNavigationController? episodeNav;
  final Future<void> Function(int absoluteSeconds)? onSeekToAbsolute;

  const SettingsMenu({
    super.key,
    required this.player,
    required this.onClose,
    required this.currentFit,
    required this.onFitChanged,
    this.playerController,
    this.episodeNav,
    this.onSeekToAbsolute,
  });

  @override
  State<SettingsMenu> createState() => _SettingsMenuState();
}

class _SettingsMenuState extends State<SettingsMenu> {
  late BoxFit _fit;
  bool _isExtractingSubtitles = false;
  int _tabIndex = 0;
  StreamSubscription<void>? _tracksSubscription;

  static const _tabs = [
    PlayerSettingsTab(icon: Icons.audiotrack_rounded, label: 'Audio'),
    PlayerSettingsTab(icon: Icons.subtitles_outlined, label: 'Sous-titres'),
    PlayerSettingsTab(icon: Icons.aspect_ratio_rounded, label: 'Affichage'),
  ];

  static const _tabsWithChapters = [
    PlayerSettingsTab(icon: Icons.audiotrack_rounded, label: 'Audio'),
    PlayerSettingsTab(icon: Icons.subtitles_outlined, label: 'Sous-titres'),
    PlayerSettingsTab(icon: Icons.aspect_ratio_rounded, label: 'Affichage'),
    PlayerSettingsTab(icon: Icons.list_alt_rounded, label: 'Chapitres'),
  ];

  @override
  void initState() {
    super.initState();
    _fit = widget.currentFit;
    _tracksSubscription = widget.playerController?.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tracksSubscription?.cancel();
    super.dispose();
  }

  String _audioTrackName(mk.AudioTrack track, int index) {
    if (track.id == 'no') return 'Désactivé';
    return track.title ??
        (track.language != null ? 'Audio (${track.language})' : 'Audio ${index + 1}');
  }

  String _subtitleTrackName(mk.SubtitleTrack track, int index) {
    if (track.id == 'no') return 'Désactivés';
    return track.title ??
        (track.language != null ? 'Sous-titre (${track.language})' : 'Sous-titre ${index + 1}');
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
    final tracks = widget.player.state.tracks;
    final currentAudio = widget.player.state.track.audio;
    final currentSubtitle = widget.player.state.track.subtitle;
    final controller = widget.playerController;
    final mediaTracks = controller?.mediaTracks;

    return GestureDetector(
      onTap: () {},
      child: PlayerSettingsShell(
        width: _panelWidth,
        maxHeight: _panelHeight,
        onClose: widget.onClose,
        tabs: _activeTabs,
        selectedTab: _tabIndex.clamp(0, _activeTabs.length - 1),
        onTabSelected: (i) => setState(() => _tabIndex = i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: IndexedStack(
            index: _tabIndex.clamp(0, _activeTabs.length - 1),
            children: [
              (controller != null && mediaTracks != null && mediaTracks.audio.isNotEmpty)
                  ? _buildCanonicalAudioList(mediaTracks.audio, controller)
                  : _buildTrackList(
                      tracks.audio,
                      currentAudio,
                      (track) => _audioTrackName(track, tracks.audio.indexOf(track)),
                      (track) => widget.player.setAudioTrack(track),
                    ),
              (controller != null && mediaTracks != null)
                  ? _buildSubtitleTab(mediaTracks.subtitles, controller)
                  : _buildTrackList(
                      tracks.subtitle,
                      currentSubtitle,
                      (track) =>
                          _subtitleTrackName(track, tracks.subtitle.indexOf(track)),
                      (track) => widget.player.setSubtitleTrack(track),
                    ),
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
      ),
    )
        .animate()
        .fadeIn(duration: 220.ms, curve: Curves.easeOut)
        .slideY(begin: -0.04, end: 0, duration: 220.ms, curve: Curves.easeOutCubic)
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
            widget.onClose();
          },
        );
      },
    );
  }

  Widget _buildDisplayOptions() {
    return ListView(
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

  Widget _buildCanonicalAudioList(
    List<MediaAudioTrack> audioTracks,
    PlayerController controller,
  ) {
    if (audioTracks.isEmpty) {
      return const _EmptyTracksMessage();
    }

    return ListView.builder(
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
            widget.onClose();
          },
        );
      },
    );
  }

  Widget _buildSubtitleTab(
    List<MediaSubtitleTrack> subtitles,
    PlayerController controller,
  ) {
    final useInternal = controller.currentQuality == null;

    return Column(
      children: [
        Expanded(
          child: useInternal
              ? _buildInternalSubtitleList(controller)
              : _buildCanonicalSubtitleList(subtitles, controller),
        ),
        if (subtitles.any((s) => !s.ready))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: (_isExtractingSubtitles || controller.isExtractingSubtitles)
                    ? null
                    : () => _forceExtractSubtitles(controller),
                icon: (_isExtractingSubtitles || controller.isExtractingSubtitles)
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(
                  (_isExtractingSubtitles || controller.isExtractingSubtitles)
                      ? 'Extraction en cours…'
                      : 'Extraire les sous-titres',
                  style: const TextStyle(fontSize: 12, fontFamily: 'Manrope'),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF007AFF),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _forceExtractSubtitles(PlayerController controller) async {
    setState(() => _isExtractingSubtitles = true);
    try {
      final subs = await controller.forceExtractSubtitles();
      if (!mounted) return;
      setState(() => _isExtractingSubtitles = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            subs.isEmpty
                ? 'Aucun sous-titre texte trouvé dans ce fichier'
                : '${subs.length} piste${subs.length > 1 ? 's' : ''} extraite${subs.length > 1 ? 's' : ''}',
          ),
          backgroundColor: subs.isEmpty ? Colors.orange.shade800 : Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isExtractingSubtitles = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Extraction échouée : $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Widget _buildInternalSubtitleList(PlayerController controller) {
    final subs = widget.player.state.tracks.subtitle
        .where((t) => t.id != 'auto')
        .toList();
    final current = widget.player.state.track.subtitle;
    return _buildTrackList(
      subs,
      current,
      (track) => _subtitleTrackName(track, subs.indexOf(track)),
      (track) => controller.selectInternalSubtitle(track),
    );
  }

  Widget _buildCanonicalSubtitleList(
    List<MediaSubtitleTrack> subtitles,
    PlayerController controller,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4),
      itemCount: subtitles.length + 1,
      itemBuilder: (context, row) {
        if (row == 0) {
          return PlayerSettingsTrackRow(
            label: 'Désactivés',
            selected: controller.selectedSubtitleLang == null,
            onTap: () {
              controller.setSubtitle(null);
              widget.onClose();
            },
          );
        }
        final index = row - 1;
        final track = subtitles[index];
        final (title, subtitle) = splitTrackLabel(track.displayName);

        return PlayerSettingsTrackRow(
          label: title,
          subtitle: subtitle,
          badge: track.ready ? null : '…',
          selected: controller.selectedSubtitleLang == track.lang,
          onTap: () {
            controller.setSubtitle(track.lang);
            widget.onClose();
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
