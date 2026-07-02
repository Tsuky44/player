import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import '../../../widgets/global/control_chrome.dart';

/// Full-screen preview of the current layout without any editing chrome.
///
/// Renders a dummy video background and all placed controls at their
/// relative positions so the user can see how the layout will look in the
/// real player.
class StudioPreview extends StatelessWidget {
  final PlayerLayoutConfig config;

  const StudioPreview({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Dummy video background
          const _DummyVideoBackground(),

          // Controls positioned via LayoutBuilder
          LayoutBuilder(
            builder: (context, constraints) {
              final canvasSize = constraints.biggest;
              return Stack(
                children: [
                  for (final placed in config.controls)
                    _positionedControl(placed, canvasSize),
                ],
              );
            },
          ),

          // Close button
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Material(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => Navigator.pop(context),
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.close, color: Colors.white, size: 24),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionedControl(PlacedControl placed, Size canvasSize) {
    final c = placed.config;
    return Align(
      alignment: Alignment(c.xPercentage * 2 - 1, c.yPercentage * 2 - 1),
      child: IgnorePointer(
        child: ControlChrome(
          type: placed.type,
          sizePercentage: c.sizePercentage,
          canvasSize: canvasSize,
          widthPercentage: c.widthPercentage,
          variant: ControlChromeVariant.live,
          isPlaying: true,
          progress: 0.35,
          duration: placed.type == PlayerControlType.timeline
              ? const Duration(hours: 1, minutes: 23, seconds: 45)
              : null,
          currentSeconds: placed.type == PlayerControlType.timeline ? 521 : null,
          onToggleFullscreen: placed.type == PlayerControlType.timeline ? () {} : null,
          mediaTitle: placed.type == PlayerControlType.mediaTitle ||
                  placed.type == PlayerControlType.mediaLogo
              ? 'Arcane – S01E02'
              : null,
          mediaLogoUrl: placed.type == PlayerControlType.mediaLogo ? null : null,
          volume: placed.type == PlayerControlType.volumeSlider ? 65.0 : null,
          onVolumeChanged: placed.type == PlayerControlType.volumeSlider ? (_) {} : null,
          onBack: placed.type == PlayerControlType.back ? () {} : null,
          blurSigma: config.blurIntensity,
          glassOpacity: config.glassOpacity,
          liquidGlass: config.liquidGlass,
        ),
      ),
    );
  }
}

class _DummyVideoBackground extends StatelessWidget {
  const _DummyVideoBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2B3A4A), Color(0xFF0F1215)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_creation_outlined,
                size: 64, color: Colors.white.withOpacity(0.12)),
            const SizedBox(height: 12),
            Text(
              'APERÇU PLEIN ÉCRAN',
              style: TextStyle(
                color: Colors.white.withOpacity(0.12),
                fontSize: 16,
                letterSpacing: 6,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
