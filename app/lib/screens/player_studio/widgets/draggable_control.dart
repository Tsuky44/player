import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import '../../../widgets/global/control_chrome.dart';

/// A studio control the user can drag around the canvas.
class DraggableControl extends StatelessWidget {
  final GlobalKey boundsKey;
  final PlacedControl placed;
  final Size canvasSize;
  final bool selected;
  final bool isDragging;
  final VoidCallback onSelect;
  final void Function(TapDownDetails details)? onSecondaryTapDown;
  final void Function(Offset delta) onDrag;
  final VoidCallback onDragEnd;
  final double blurSigma;
  final double glassOpacity;
  final bool liquidGlass;

  const DraggableControl({
    super.key,
    required this.boundsKey,
    required this.placed,
    required this.canvasSize,
    required this.selected,
    this.isDragging = false,
    required this.onSelect,
    this.onSecondaryTapDown,
    required this.onDrag,
    required this.onDragEnd,
    this.blurSigma = kDefaultBlurSigma,
    this.glassOpacity = kDefaultGlassOpacity,
    this.liquidGlass = kDefaultLiquidGlass,
  });

  @override
  Widget build(BuildContext context) {
    final isFullWidthTimeline =
        placed.type == PlayerControlType.timelineEmby ||
        placed.type == PlayerControlType.timelineGlassInline;

    return AnimatedAlign(
      duration: isDragging ? Duration.zero : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      alignment: Alignment(
        isFullWidthTimeline ? 0 : placed.config.xPercentage * 2 - 1,
        placed.config.yPercentage * 2 - 1,
      ),
      widthFactor: isFullWidthTimeline ? 1.0 : null,
      child: Padding(
        padding: isFullWidthTimeline
            ? const EdgeInsets.symmetric(horizontal: 16)
            : EdgeInsets.zero,
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onSelect(),
        onPanUpdate: (details) => onDrag(details.delta),
        onPanEnd: (_) => onDragEnd(),
        onTap: onSelect,
        onSecondaryTapDown: onSecondaryTapDown,
        child: KeyedSubtree(
          key: boundsKey,
            child: ControlChrome(
              type: placed.type,
              sizePercentage: placed.config.sizePercentage,
              canvasSize: canvasSize,
              widthPercentage: placed.config.widthPercentage,
              variant: ControlChromeVariant.studio,
              selected: selected,
              timelineOptions: placed.type.isTimelineBar
                  ? placed.effectiveTimelineOptions
                  : const TimelineChromeOptions(showFullscreen: true),
              duration: placed.type.isTimelineBar
                  ? const Duration(hours: 1, minutes: 23, seconds: 45)
                  : null,
              currentSeconds:
                  placed.type.isTimelineBar ? 521 : null,
              onToggleFullscreen: placed.type.isTimelineBar
                  ? () {}
                  : null,
              onPlayPause:
                  placed.type.isTimelineBar ? () {} : null,
              onRewind: placed.type.isTimelineBar ? () {} : null,
              onForward: placed.type.isTimelineBar ? () {} : null,
              onSkipPrevious:
                  placed.type.isTimelineBar ? () {} : null,
              onSkipNext: placed.type.isTimelineBar ? () {} : null,
              onOpenSettings:
                  placed.type.isTimelineBar ? () {} : null,
              onToggleSubtitles:
                  placed.type.isTimelineBar ? () {} : null,
              mediaTitle: placed.type == PlayerControlType.mediaTitle ||
                      placed.type == PlayerControlType.mediaLogo
                  ? 'Arcane – S01E02'
                  : null,
              mediaLogoUrl:
                  placed.type == PlayerControlType.mediaLogo ? null : null,
              volume: placed.type == PlayerControlType.volumeSlider ? 65.0 : null,
              onVolumeChanged: placed.type == PlayerControlType.volumeSlider
                  ? (_) {}
                  : null,
              onBack: placed.type == PlayerControlType.back ? () {} : null,
              blurSigma: blurSigma,
              glassOpacity: glassOpacity,
              liquidGlass: liquidGlass,
            ),
          ),
        ),
      ),
    );
  }
}
