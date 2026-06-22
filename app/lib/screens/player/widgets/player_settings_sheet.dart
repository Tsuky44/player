import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:media_kit/media_kit.dart' as mk;
import '../hooks/use_player_controller.dart';

/// Bottom-sheet widget that lets the user pick audio / subtitle tracks,
/// switch the video display mode (fit vs cover), and select transcoding quality.
class PlayerSettingsSheet extends StatefulWidget {
  final mk.Player player;
  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;
  final VoidCallback? onClose;
  final PlayerController? playerController;

  const PlayerSettingsSheet({
    super.key,
    required this.player,
    required this.currentFit,
    required this.onFitChanged,
    this.onClose,
    this.playerController,
  });

  @override
  State<PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<PlayerSettingsSheet> {
  late BoxFit _fit;

  @override
  void initState() {
    super.initState();
    _fit = widget.currentFit;
  }

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  String _audioTrackName(mk.AudioTrack track, int index) {
    if (track.id == 'no') return 'Désactivé';
    return track.title ??
        (track.language != null ? 'Audio (${track.language})' : 'Audio ${index + 1}');
  }

  String _subtitleTrackName(mk.SubtitleTrack track, int index) {
    if (track.id == 'no') return 'Désactivés';
    return track.title ??
        (track.language != null
            ? 'Sous-titre (${track.language})'
            : 'Sous-titre ${index + 1}');
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.player.state.tracks;
    final currentAudio = widget.player.state.track.audio;
    final currentSubtitle = widget.player.state.track.subtitle;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300, maxHeight: 380),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A).withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
                width: 1,
              ),
            ),
            child: DefaultTabController(
              length: 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Row(
                    children: [
                      const Text(
                        'Paramètres',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Manrope',
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _close,
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.close,
                              color: Colors.white.withOpacity(0.7),
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Tab bar
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: TabBar(
                      indicator: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      dividerColor: Colors.transparent,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white.withOpacity(0.5),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Manrope',
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Manrope',
                      ),
                      tabs: const [
                        Tab(text: 'Audio'),
                        Tab(text: 'Sous-titres'),
                        Tab(text: 'Affichage'),
                        Tab(text: 'Qualité'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Tab content
                  Flexible(
                    child: TabBarView(
                      children: [
                        _buildTrackList(
                          tracks.audio,
                          currentAudio,
                          (track) => _audioTrackName(track, tracks.audio.indexOf(track)),
                          (track) => widget.player.setAudioTrack(track),
                        ),
                        _buildTrackList(
                          tracks.subtitle,
                          currentSubtitle,
                          (track) => _subtitleTrackName(track, tracks.subtitle.indexOf(track)),
                          (track) => widget.player.setSubtitleTrack(track),
                        ),
                        _buildDisplayOptions(),
                        _buildQualityOptions(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 200.ms, curve: Curves.easeOut);
  }

  Widget _buildTrackList<T>(
    List<T> tracks,
    T? currentTrack,
    String Function(T) getName,
    void Function(T) onSelect,
  ) {
    if (tracks.isEmpty) {
      return const Center(
        child: Text(
          'Aucune piste disponible',
          style: TextStyle(
            color: Colors.grey,
            fontSize: 13,
            fontFamily: 'Manrope',
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final isSelected = track == currentTrack;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              onSelect(track);
              _close();
            },
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withOpacity(0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  if (isSelected)
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF007AFF),
                        shape: BoxShape.circle,
                      ),
                    )
                  else
                    const SizedBox(width: 6),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      getName(track),
                      style: TextStyle(
                        color: isSelected
                            ? Colors.white
                            : Colors.white.withOpacity(0.7),
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.w400,
                        fontFamily: 'Manrope',
                      ),
                    ),
                  ),
                  if (isSelected)
                    const Icon(
                      Icons.check,
                      color: Color(0xFF007AFF),
                      size: 18,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDisplayOptions() {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      children: [
        _DisplayOption(
          icon: Icons.fit_screen,
          label: 'Original',
          subtitle: 'Conserve les proportions, bandes noires possibles',
          selected: _fit == BoxFit.contain,
          onTap: () {
            setState(() => _fit = BoxFit.contain);
            widget.onFitChanged(BoxFit.contain);
          },
        ),
        const SizedBox(height: 8),
        _DisplayOption(
          icon: Icons.crop_free,
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

    final qualities = [
      ('Direct', null, Icons.bolt, 'Lecture directe, aucune transcodation'),
      ('360p', '360p', Icons.sd, '640x360 — Faible consommation'),
      ('480p', '480p', Icons.sd, '854x480 — Qualité standard'),
      ('720p', '720p', Icons.hd, '1280x720 — HD'),
      ('1080p', '1080p', Icons.hd_outlined, '1920x1080 — Full HD'),
    ];

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      itemCount: qualities.length,
      itemBuilder: (context, index) {
        final (label, quality, icon, subtitle) = qualities[index];
        final isSelected = currentQuality == quality;

        return Padding(
          padding: EdgeInsets.only(bottom: index < qualities.length - 1 ? 8 : 0),
          child: _DisplayOption(
            icon: icon,
            label: label,
            subtitle: subtitle,
            selected: isSelected,
            onTap: () {
              if (controller == null) return;
              if (quality == null) {
                controller.switchToDirectPlay();
              } else {
                controller.switchToQuality(quality);
              }
              setState(() {});
              _close();
            },
          ),
        );
      },
    );
  }
}

class _DisplayOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _DisplayOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withOpacity(0.12)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? const Color(0xFF007AFF).withOpacity(0.5)
                  : Colors.white.withOpacity(0.08),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF007AFF).withOpacity(0.2)
                      : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: selected
                      ? const Color(0xFF007AFF)
                      : Colors.white.withOpacity(0.7),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        fontFamily: 'Manrope',
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12,
                        fontFamily: 'Manrope',
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF007AFF),
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
