import 'package:flutter/material.dart';
import '../../../models/player_layout.dart';
import 'studio_drawer_shell.dart';

/// Side drawer for choosing the preset's control skin (Verre/Net/Doux) and
/// tuning that skin's own parameters (glass blur/opacity/liquid, flat accent
/// colour/elevation, or neumorphic intensity).
class GlassStyleDrawer extends StatelessWidget {
  final ControlSkinStyle skin;
  final double blurIntensity;
  final double glassOpacity;
  final bool liquidGlass;
  final Color flatAccentColor;
  final FlatElevation flatElevation;
  final double neumorphicIntensity;
  final ValueChanged<ControlSkinStyle> onSkinChanged;
  final ValueChanged<double> onBlurChanged;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<bool> onLiquidGlassChanged;
  final ValueChanged<Color> onFlatAccentColorChanged;
  final ValueChanged<FlatElevation> onFlatElevationChanged;
  final ValueChanged<double> onNeumorphicIntensityChanged;

  const GlassStyleDrawer({
    super.key,
    required this.skin,
    required this.blurIntensity,
    required this.glassOpacity,
    required this.liquidGlass,
    required this.flatAccentColor,
    required this.flatElevation,
    required this.neumorphicIntensity,
    required this.onSkinChanged,
    required this.onBlurChanged,
    required this.onOpacityChanged,
    required this.onLiquidGlassChanged,
    required this.onFlatAccentColorChanged,
    required this.onFlatElevationChanged,
    required this.onNeumorphicIntensityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return StudioDrawerShell(
      title: 'Style',
      icon: Icons.palette_outlined,
      subtitle: 'Habillage visuel appliqué à tous les contrôles du lecteur.',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: [
          SegmentedButton<ControlSkinStyle>(
            segments: [
              for (final s in ControlSkinStyle.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {skin},
            onSelectionChanged: (v) => onSkinChanged(v.first),
            style: SegmentedButton.styleFrom(
              backgroundColor: const Color(0xFF252525),
              foregroundColor: Colors.grey,
              selectedForegroundColor: Colors.white,
              selectedBackgroundColor: const Color(0xFF0A84FF),
            ),
          ),
          const SizedBox(height: 24),
          switch (skin) {
            ControlSkinStyle.glass => _GlassSection(
                blurIntensity: blurIntensity,
                glassOpacity: glassOpacity,
                liquidGlass: liquidGlass,
                onBlurChanged: onBlurChanged,
                onOpacityChanged: onOpacityChanged,
                onLiquidGlassChanged: onLiquidGlassChanged,
              ),
            ControlSkinStyle.flat => _FlatSection(
                accentColor: flatAccentColor,
                elevation: flatElevation,
                onAccentColorChanged: onFlatAccentColorChanged,
                onElevationChanged: onFlatElevationChanged,
              ),
            ControlSkinStyle.neumorphic => _NeumorphicSection(
                intensity: neumorphicIntensity,
                onIntensityChanged: onNeumorphicIntensityChanged,
              ),
          },
        ],
      ),
    );
  }
}

class _GlassSection extends StatelessWidget {
  final double blurIntensity;
  final double glassOpacity;
  final bool liquidGlass;
  final ValueChanged<double> onBlurChanged;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<bool> onLiquidGlassChanged;

  const _GlassSection({
    required this.blurIntensity,
    required this.glassOpacity,
    required this.liquidGlass,
    required this.onBlurChanged,
    required this.onOpacityChanged,
    required this.onLiquidGlassChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: liquidGlass,
          onChanged: onLiquidGlassChanged,
          activeColor: const Color(0xFF0A84FF),
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
    );
  }
}

class _FlatSection extends StatelessWidget {
  final Color accentColor;
  final FlatElevation elevation;
  final ValueChanged<Color> onAccentColorChanged;
  final ValueChanged<FlatElevation> onElevationChanged;

  const _FlatSection({
    required this.accentColor,
    required this.elevation,
    required this.onAccentColorChanged,
    required this.onElevationChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Couleur d’accent',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final color in kFlatAccentPalette)
              _AccentSwatch(
                color: color,
                selected: color.toARGB32() == accentColor.toARGB32(),
                onTap: () => onAccentColorChanged(color),
              ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Élévation',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<FlatElevation>(
          segments: [
            for (final e in FlatElevation.values)
              ButtonSegment(value: e, label: Text(e.label)),
          ],
          selected: {elevation},
          onSelectionChanged: (v) => onElevationChanged(v.first),
          style: SegmentedButton.styleFrom(
            backgroundColor: const Color(0xFF252525),
            foregroundColor: Colors.grey,
            selectedForegroundColor: Colors.white,
            selectedBackgroundColor: const Color(0xFF0A84FF),
          ),
        ),
      ],
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _AccentSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }
}

class _NeumorphicSection extends StatelessWidget {
  final double intensity;
  final ValueChanged<double> onIntensityChanged;

  const _NeumorphicSection({
    required this.intensity,
    required this.onIntensityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassSliderRow(
      label: 'Intensité',
      valueLabel: '${(intensity * 100).round()}%',
      value: intensity,
      min: kMinNeumorphicIntensity,
      max: kMaxNeumorphicIntensity,
      onChanged: onIntensityChanged,
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
            activeTrackColor: const Color(0xFF0A84FF),
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
