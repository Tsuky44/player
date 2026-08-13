import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import '../hooks/use_studio_controller.dart';

/// Compact floating menu shown on right-click over a canvas control.
class ControlContextMenu extends StatelessWidget {
  final PlacedControl placed;
  final StudioController controller;
  final VoidCallback onClose;
  final VoidCallback? onOpenFullEditor;
  final ValueChanged<Offset>? onDragDelta;

  const ControlContextMenu({
    super.key,
    required this.placed,
    required this.controller,
    required this.onClose,
    this.onOpenFullEditor,
    this.onDragDelta,
  });

  bool get _showWidth =>
      placed.type.isProgressBar || placed.type == PlayerControlType.volumeSlider;

  @override
  Widget build(BuildContext context) {
    final config = placed.config;
    final isTimeline = placed.type.isTimelineBar;
    final tlOpts = isTimeline ? placed.effectiveTimelineOptions : null;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 268,
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: const Color(0xFF242424),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) => onDragDelta?.call(details.delta),
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 8, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.drag_indicator,
                          color: Colors.white.withOpacity(0.35),
                          size: 18,
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          placed.type.icon,
                          color: Colors.white.withOpacity(0.85),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            placed.type.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: Colors.white.withOpacity(0.5),
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CompactSlider(
                        label: 'Taille',
                        value: config.sizePercentage,
                        min: kMinSizePct,
                        max: kMaxSizePct,
                        onChanged: controller.setSelectedSizePercentage,
                      ),
                      if (_showWidth) ...[
                        const SizedBox(height: 10),
                        _CompactSlider(
                          label: 'Largeur',
                          value: config.widthPercentage.clamp(0.1, 1.0),
                          min: 0.1,
                          max: 1.0,
                          onChanged: controller.setSelectedWidthPercentage,
                        ),
                      ],
                      if (isTimeline && tlOpts != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Boutons',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _CompactToggle(
                          label: 'Paramètres',
                          value: tlOpts.showSettings,
                          onChanged: (v) => controller.setSelectedTimelineOptions(
                            tlOpts.copyWith(showSettings: v),
                          ),
                        ),
                        _CompactToggle(
                          label: 'Sous-titres',
                          value: tlOpts.showSubtitles,
                          onChanged: (v) => controller.setSelectedTimelineOptions(
                            tlOpts.copyWith(showSubtitles: v),
                          ),
                        ),
                        _CompactToggle(
                          label: 'Plein écran',
                          value: tlOpts.showFullscreen,
                          onChanged: (v) => controller.setSelectedTimelineOptions(
                            tlOpts.copyWith(showFullscreen: v),
                          ),
                        ),
                        _CompactToggle(
                          label: 'À suivre',
                          value: tlOpts.showUpNext,
                          onChanged: (v) => controller.setSelectedTimelineOptions(
                            tlOpts.copyWith(showUpNext: v),
                          ),
                        ),
                        _CompactToggle(
                          label: 'Lecture / Pause',
                          value: tlOpts.showPlayPause,
                          onChanged: (v) => controller.setSelectedTimelineOptions(
                            tlOpts.copyWith(showPlayPause: v),
                          ),
                        ),
                        if (onOpenFullEditor != null) ...[
                          const SizedBox(height: 4),
                          TextButton.icon(
                            onPressed: onOpenFullEditor,
                            icon: const Icon(Icons.tune, size: 16),
                            label: const Text('Tous les réglages'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF0A84FF),
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: Colors.white.withOpacity(0.08)),
              InkWell(
                onTap: () {
                  controller.removeControl(placed.id);
                  onClose();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Colors.red.shade400,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Supprimer',
                        style: TextStyle(
                          color: Colors.red.shade400,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _CompactSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.75),
                fontSize: 12,
              ),
            ),
            const Spacer(),
            Text(
              '${(clamped * 100).round()}%',
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: const Color(0xFF0A84FF),
            inactiveTrackColor: Colors.white.withOpacity(0.12),
            thumbColor: Colors.white,
            overlayColor: const Color(0xFF0A84FF).withOpacity(0.15),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            min: min,
            max: max,
            value: clamped,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _CompactToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CompactToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 12,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFF0A84FF),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
