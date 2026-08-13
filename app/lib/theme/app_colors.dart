import 'package:flutter/material.dart';

/// Quiet Premium tokens — OLED charcoal stage, blue focus sparingly.
abstract final class AppColors {
  static const background = Color(0xFF0A0A0A);
  static const surface = Color(0xFF141414);
  static const surfaceElevated = Color(0xFF1C1C1C);
  static const surfaceHover = Color(0xFF252525);
  static const border = Color(0xFF2C2C2E);

  /// Interactive accent (focus, selection, links). Not a fill wash.
  static const primary = Color(0xFF0A84FF);
  static const accent = Color(0xFF0A84FF);
  static const accentMuted = Color(0xFF64B5FF);
  static const onAccent = Color(0xFFFFFFFF);

  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFFA1A1A6);
  static const textMuted = Color(0xFF6E6E73);

  static const progress = Color(0xFF0A84FF);
  static const success = Color(0xFF30D158);
  static const warning = Color(0xFFFF9F0A);
  static const error = Color(0xFFFF453A);

  static const gradientBottom = Color(0xFF0A0A0A);
  static const gradientTop = Colors.transparent;

  static const navBackground = Color(0xE6141414);

  /// Hairline glass edge highlight.
  static Color get glassBorder => Colors.white.withValues(alpha: 0.08);
  static Color get glassFill => Colors.white.withValues(alpha: 0.06);
  static Color get glassFillStrong => Colors.black.withValues(alpha: 0.45);
}
