import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import 'studio_drawer_shell.dart';

/// Side drawer for tuning the modular control glass look (blur, opacity, liquid).
class GlassStyleDrawer extends StatelessWidget {
  final double blurIntensity;
  final double glassOpacity;
  final bool liquidGlass;
  final ValueChanged<double> onBlurChanged;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<bool> onLiquidGlassChanged;

  const GlassStyleDrawer({
    super.key,
    required this.blurIntensity,
    required this.glassOpacity,
    required this.liquidGlass,
    required this.onBlurChanged,
    required this.onOpacityChanged,
    required this.onLiquidGlassChanged,
  });

  @override
  Widget build(BuildContext context) {
    return StudioDrawerShell(
      title: 'Effet de verre',
      icon: Icons.blur_on,
      subtitle: 'Réglages appliqués à tous les boutons du lecteur modulaire.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: liquidGlass,
            onChanged: onLiquidGlassChanged,
            activeColor: const Color(0xFF007AFF),
            title: const Text(
              'Effet liquide (style Apple)',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              liquidGlass
                  ? 'Saturation, reflets et bord lumineux'
                  : 'Verre simple — plus léger',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(height: 20),
          _GlassSliderRow(
            label: 'Flou',
            valueLabel: blurIntensity <= 0.1
                ? 'Aucun'
                : blurIntensity.toStringAsFixed(0),
            value: blurIntensity,
            min: kMinBlurSigma,
            max: kMaxBlurSigma,
            onChanged: onBlurChanged,
          ),
          const SizedBox(height: 16),
          _GlassSliderRow(
            label: 'Transparence',
            valueLabel:
                '${(100 - (glassOpacity / kMaxGlassOpacity) * 100).round()}%',
            value: glassOpacity,
            min: kMinGlassOpacity,
            max: kMaxGlassOpacity,
            onChanged: onOpacityChanged,
          ),
        ],
      ),
    );
  }
}

class _GlassSliderRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _GlassSliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            Text(
              valueLabel,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: const Color(0xFF007AFF),
            inactiveTrackColor: const Color(0xFF2A2A2A),
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
