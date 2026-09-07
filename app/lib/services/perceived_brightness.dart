import 'dart:math' as math;

/// The curve between where the finger is on the bar and what the backlight is
/// asked for.
///
/// A backlight driven straight off the slider is the reason a brightness
/// control feels broken: the eye answers to light roughly logarithmically, so
/// the bottom of the range does almost all the visible work and everything
/// above a third of it looks the same. Halfway up the bar the screen is already
/// as bright as it will ever look, and the rest of the travel does nothing the
/// user can see.
///
/// So the bar is read in *perceived* brightness and converted here. This is
/// Android's own curve — the one behind the system slider — which is the
/// hybrid log-gamma transfer function: a square law across the dark half, where
/// small absolute changes are large relative ones, and an exponential above it.
/// Using theirs rather than inventing one means the bar moves the way the
/// slider in the notification shade moves, which is the only reference the user
/// has.
abstract final class PerceivedBrightness {
  const PerceivedBrightness._();

  // The HLG constants, as Android states them.
  static const double _a = 0.17883277;
  static const double _b = 0.28466892;
  static const double _c = 0.55991073;

  /// Where the square law hands over to the exponential — the middle of the
  /// bar, and a twelfth of the backlight.
  static const double _knee = 0.5;
  static const double _kneeLinear = 1 / 12;

  /// Never quite off.
  ///
  /// A backlight at a true zero is a black screen with the control that turns
  /// it back up somewhere on it, invisible. The floor is low enough to be the
  /// dimmest a film is watchable at in the dark, and high enough that the phone
  /// still reads as on.
  static const double _floor = 0.01;

  /// What the backlight should be for a bar at [perceived] (0..1).
  static double toBacklight(double perceived) {
    final value = perceived.clamp(0.0, 1.0);
    final linear = value <= _knee
        ? _square(value / _knee) * _kneeLinear
        : (math.exp((value - _c) / _a) + _b) / 12;
    return linear.clamp(_floor, 1.0);
  }

  /// Where the bar has to sit to be showing [backlight] — the inverse, so the
  /// control opens on the brightness the screen is already at instead of
  /// jumping the moment it is touched.
  static double fromBacklight(double backlight) {
    final value = backlight.clamp(0.0, 1.0);
    final perceived = value <= _kneeLinear
        ? math.sqrt(value / _kneeLinear) * _knee
        : _a * math.log(value * 12 - _b) + _c;
    return perceived.clamp(0.0, 1.0);
  }

  static double _square(double value) => value * value;
}
