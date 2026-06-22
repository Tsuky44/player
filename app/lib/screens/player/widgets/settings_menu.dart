import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:media_kit/media_kit.dart' as mk;

class SettingsMenu extends StatefulWidget {
  final mk.Player player;
  final VoidCallback onClose;
  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;

  const SettingsMenu({
    super.key,
    required this.player,
    required this.onClose,
    required this.currentFit,
    required this.onFitChanged,
  });

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

  @override
  State<SettingsMenu> createState() => _SettingsMenuState();
}

class _SettingsMenuState extends State<SettingsMenu> {
  late BoxFit _fit;

  @override
  void initState() {
    super.initState();
    _fit = widget.currentFit;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.player.state.tracks;
    final currentAudio = widget.player.state.track.audio;
    final currentSubtitle = widget.player.state.track.subtitle;

    return Positioned(
      top: 64,
      right: 24,
      child: GestureDetector(
        onTap: () {}, // Prevent tap-through to close
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
            child: Container(
              width: 320,
              constraints: const BoxConstraints(maxHeight: 420),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A).withOpacity(0.75),
                borderRadius: BorderRadius.circular(24),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withOpacity(0.15),
                    width: 1,
                  ),
                ),
              ),
              child: DefaultTabController(
                length: 3,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Text(
                            'Paramètres',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Manrope',
                            ),
                          ),
                          const Spacer(),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: widget.onClose,
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.close,
                                  color: Colors.white.withOpacity(0.7),
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Tab bar
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TabBar(
                        indicator: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        dividerColor: Colors.transparent,
                        labelColor: Colors.white,
                        unselectedLabelColor: Colors.white.withOpacity(0.5),
                        labelStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Manrope',
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'Manrope',
                        ),
                        tabs: const [
                          Tab(text: 'Audio'),
                          Tab(text: 'Sous-titres'),
                          Tab(text: 'Affichage'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Tab content
                    Flexible(
                      child: TabBarView(
                        children: [
                          _buildTrackList(
                            tracks.audio,
                            currentAudio,
                            (track) => widget._audioTrackName(track, tracks.audio.indexOf(track)),
                            (track) => widget.player.setAudioTrack(track),
                          ),
                          _buildTrackList(
                            tracks.subtitle,
                            currentSubtitle,
                            (track) => widget._subtitleTrackName(track, tracks.subtitle.indexOf(track)),
                            (track) => widget.player.setSubtitleTrack(track),
                          ),
                          _buildDisplayOptions(),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 250.ms, curve: Curves.easeOut)
        .slideY(begin: -0.05, end: 0, duration: 250.ms, curve: Curves.easeOut)
        .scaleXY(begin: 0.95, end: 1, duration: 250.ms, curve: Curves.easeOut);
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final isSelected = track == currentTrack;

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              onSelect(track);
              widget.onClose();
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
                        color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
