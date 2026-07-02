import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import '../hooks/use_player_controller.dart';
import '../hooks/use_episode_navigation.dart';
import 'settings_menu.dart';
import 'player_settings_anchor.dart';

class TopRightControls extends StatefulWidget {
  final mk.Player player;
  final BoxFit currentFit;
  final ValueChanged<BoxFit> onFitChanged;
  final PlayerController? playerController;
  final EpisodeNavigationController? episodeNav;
  final Future<void> Function(int absoluteSeconds)? onSeekToAbsolute;

  const TopRightControls({
    super.key,
    required this.player,
    required this.currentFit,
    required this.onFitChanged,
    this.playerController,
    this.episodeNav,
    this.onSeekToAbsolute,
  });

  @override
  State<TopRightControls> createState() => _TopRightControlsState();
}

class _TopRightControlsState extends State<TopRightControls> {
  bool _isVolumeHovering = false;
  bool _showSettings = false;
  final GlobalKey _settingsButtonKey = GlobalKey();

  void _toggleSettings() {
    setState(() => _showSettings = !_showSettings);
  }

  void _closeSettings() {
    if (_showSettings) setState(() => _showSettings = false);
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.player.state.volume;
    final isMuted = volume <= 0;

    return Stack(
      children: [
        // Settings button (left of volume)
        Positioned(
          top: 16,
          right: 72, // 24 (volume right) + 40 (volume width) + 8 (gap)
          child: Material(
            key: _settingsButtonKey,
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggleSettings,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  _showSettings ? Icons.close : Icons.settings_outlined,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),

        // Volume slider
        Positioned(
          top: 16,
          right: 24,
          child: MouseRegion(
            onEnter: (_) => setState(() => _isVolumeHovering = true),
            onExit: (_) => setState(() => _isVolumeHovering = false),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  height: 40,
                  width: _isVolumeHovering ? 180 : 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A).withOpacity(0.6),
                    borderRadius: BorderRadius.circular(24),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withOpacity(0.15),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (isMuted) {
                              widget.player.setVolume(100);
                            } else {
                              widget.player.setVolume(0);
                            }
                            setState(() {});
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            child: Icon(
                              isMuted ? Icons.volume_off : Icons.volume_up,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                      if (_isVolumeHovering)
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: const Color(0xFF007AFF),
                                inactiveTrackColor: Colors.white.withOpacity(0.2),
                                thumbColor: Colors.white,
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5,
                                  elevation: 0,
                                  pressedElevation: 0,
                                ),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                              ),
                              child: Slider(
                                value: volume.clamp(0.0, 100.0),
                                min: 0,
                                max: 100,
                                onChanged: (v) {
                                  widget.player.setVolume(v);
                                  setState(() {});
                                },
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // Settings menu overlay — anchored to the settings button
        if (_showSettings)
          Builder(
            builder: (context) {
              final renderBox =
                  _settingsButtonKey.currentContext?.findRenderObject() as RenderBox?;
              if (renderBox == null) return const SizedBox.shrink();

              final buttonRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;
              final screenSize = MediaQuery.sizeOf(context);
              final hasChaptersTab = widget.episodeNav != null &&
                  widget.onSeekToAbsolute != null &&
                  widget.playerController != null;
              final menuWidth =
                  PlayerSettingsAnchor.menuWidth(hasChaptersTab: hasChaptersTab);
              final menuMaxHeight =
                  PlayerSettingsAnchor.menuMaxHeight(hasChaptersTab: hasChaptersTab);
              final left = PlayerSettingsAnchor.horizontalLeft(
                buttonRect: buttonRect,
                screenSize: screenSize,
                popupWidth: menuWidth,
              );
              final vertical = PlayerSettingsAnchor.verticalPlacement(
                buttonRect: buttonRect,
                screenSize: screenSize,
                popupMaxHeight: menuMaxHeight,
              );

              return Positioned(
                left: left,
                bottom: vertical.bottom,
                top: vertical.top,
                child: SettingsMenu(
                  player: widget.player,
                  onClose: _closeSettings,
                  currentFit: widget.currentFit,
                  onFitChanged: widget.onFitChanged,
                  playerController: widget.playerController,
                  episodeNav: widget.episodeNav,
                  onSeekToAbsolute: widget.onSeekToAbsolute,
                ),
              );
            },
          ),
      ],
    );
  }
}
