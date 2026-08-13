import 'package:flutter/material.dart';

import '../../../models/player_layout.dart';
import '../../player/widgets/emby/emby_controls_layer.dart';

/// What Player Studio shows when the active playeur is a fixed chrome.
///
/// The chrome is rendered for real — same widget as the player — but frozen:
/// nothing here is draggable, because there is nothing in it to place. The
/// banner says so, and offers the way back to a modular playeur.
class FixedChromePreview extends StatelessWidget {
  final FixedChromeId chrome;

  /// Opens the template picker so the user can leave the fixed chrome.
  final VoidCallback onCreateModular;

  const FixedChromePreview({
    super.key,
    required this.chrome,
    required this.onCreateModular,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildBanner(context),
        const SizedBox(height: 16),
        Flexible(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: const Color(0xFF141414),
                // Absorbing rather than ignoring: taps must die here, not
                // fall through to whatever is behind the canvas.
                child: AbsorbPointer(child: _buildChrome()),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChrome() {
    switch (chrome) {
      case FixedChromeId.emby:
        return EmbyControlsLayer(
          visible: true,
          isPlaying: false,
          // Sample values: a preview with a zeroed timeline reads as broken.
          position: const Duration(minutes: 42, seconds: 17),
          duration: const Duration(hours: 1, minutes: 58),
          buffered: 0.48,
          title: 'Aperçu du playeur',
          overline: '2022',
          volume: 70,
          playbackRate: 1.0,
          chapterMarks: const [0.08, 0.31, 0.55, 0.79],
          onPlayPause: () {},
          onRewind: () {},
          onForward: () {},
          onSeekFraction: (_) {},
          onVolumeChanged: (_) {},
          onBack: () {},
          onToggleSubtitles: () {},
          onOpenAudio: () {},
          onCycleSpeed: () {},
          onOpenSettings: () {},
          onToggleFullscreen: () {},
        );
    }
  }

  Widget _buildBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '« ${chrome.label} » n’est pas modifiable',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Ce playeur est fixe : sa disposition et son thème sont figés.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: onCreateModular,
            child: const Text('Créer un playeur modulaire'),
          ),
        ],
      ),
    );
  }
}
