import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import '../../../widgets/global/control_chrome.dart';

/// A studio control the user can drag around the canvas.
class DraggableControl extends StatelessWidget {
  final PlacedControl placed;
  final Size canvasSize;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset delta) onDrag;
  final VoidCallback onDragEnd;

  const DraggableControl({
    super.key,
    required this.placed,
    required this.canvasSize,
    required this.selected,
    required this.onTap,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedAlign(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      alignment: Alignment(
        placed.config.xPercentage * 2 - 1,
        placed.config.yPercentage * 2 - 1,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanStart: (_) => onTap(),
        onPanUpdate: (details) => onDrag(details.delta),
        onPanEnd: (_) => onDragEnd(),
        child: AnimatedScale(
          scale: selected ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: ControlChrome(
            type: placed.type,
            sizePercentage: placed.config.sizePercentage,
            canvasSize: canvasSize,
            widthPercentage: placed.config.widthPercentage,
            variant: ControlChromeVariant.studio,
            selected: selected,
            duration: placed.type == PlayerControlType.timeline
                ? const Duration(hours: 1, minutes: 23, seconds: 45)
                : null,
            currentSeconds: placed.type == PlayerControlType.timeline ? 521 : null,
            onToggleFullscreen: placed.type == PlayerControlType.timeline ? () {} : null,
            mediaTitle: placed.type == PlayerControlType.mediaTitle ? 'Arcane – S01E02' : null,
            volume: placed.type == PlayerControlType.volumeSlider ? 65.0 : null,
            onVolumeChanged: placed.type == PlayerControlType.volumeSlider ? (_) {} : null,
            onBack: placed.type == PlayerControlType.back ? () {} : null,
          ),
        ),
      ),
    );
  }
}
