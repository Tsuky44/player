// This file is obsolete - replaced by top_right_controls.dart
// Keeping as placeholder to avoid import errors during transition
// TODO: Remove this file after confirming build works
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;

@deprecated
class VolumeSlider extends StatefulWidget {
  final mk.Player player;

  const VolumeSlider({super.key, required this.player});

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final volume = widget.player.state.volume;
    final isMuted = volume <= 0;

    return Positioned(
      top: 16,
      right: 24,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              height: 40,
              width: _isHovering ? 180 : 40,
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
                  if (_isHovering)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: const Color(0xFF0A84FF),
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
    );
  }
}
