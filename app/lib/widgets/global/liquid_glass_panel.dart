import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/player_layout.dart';

/// Floating frosted panel with optional Apple-style liquid glass treatment.
class LiquidGlassPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double glassOpacity;
  final bool liquidGlass;
  final List<BoxShadow>? boxShadow;

  const LiquidGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.blurSigma = kDefaultBlurSigma,
    this.glassOpacity = 0.12,
    this.liquidGlass = true,
    this.boxShadow,
  });

  static List<double> liquidGlassMatrix({
    required double saturation,
    double brightness = 1.0,
  }) {
    const lumR = 0.213, lumG = 0.715, lumB = 0.072;
    final s = saturation;
    final sr = (1 - s) * lumR;
    final sg = (1 - s) * lumG;
    final sb = (1 - s) * lumB;
    final b = (brightness - 1.0) * 255.0;
    return [
      sr + s, sg, sb, 0, b,
      sr, sg + s, sb, 0, b,
      sr, sg, sb + s, 0, b,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!liquidGlass) {
      return _simpleGlass();
    }
    return _liquidGlass();
  }

  Widget _simpleGlass() {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55 + glassOpacity),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: boxShadow,
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _liquidGlass() {
    final o = glassOpacity;
    final backdrop = ImageFilter.compose(
      outer: ColorFilter.matrix(
        liquidGlassMatrix(saturation: 1.55, brightness: 1.05),
      ),
      inner: ImageFilter.blur(sigmaX: blurSigma + 6, sigmaY: blurSigma + 6),
    );
    final sheen = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: (o * 2.2 + 0.06).clamp(0.06, 0.42)),
        Colors.white.withValues(alpha: (o * 0.5 + 0.02).clamp(0.02, 0.16)),
      ],
    );
    final specular = LinearGradient(
      begin: Alignment.topCenter,
      end: const Alignment(0, 0.55),
      colors: [
        Colors.white.withValues(alpha: (o * 2.5 + 0.14).clamp(0.14, 0.45)),
        Colors.transparent,
      ],
    );
    final rim = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: (o * 3 + 0.28).clamp(0.22, 0.65)),
        Colors.white.withValues(alpha: (o + 0.04).clamp(0.04, 0.18)),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: rim,
        boxShadow: boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
      ),
      padding: const EdgeInsets.all(1.1),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: backdrop,
          child: Container(
            decoration: BoxDecoration(gradient: sheen, borderRadius: borderRadius),
            foregroundDecoration:
                BoxDecoration(gradient: specular, borderRadius: borderRadius),
            child: child,
          ),
        ),
      ),
    );
  }
}
