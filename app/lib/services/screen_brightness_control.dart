import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../utils/app_platform.dart';
import '../tv/tv_mode.dart';
import 'perceived_brightness.dart';

/// The screen's own backlight, for the duration of a playback.
///
/// Every media player on a phone owns this control, and for the same reason:
/// a film graded dark is unwatchable at the brightness the phone picked for a
/// text message in daylight, and turning the system brightness up for the film
/// leaves it up afterwards. The plugin's *application* brightness is exactly
/// that distinction — an override that belongs to this app and is dropped the
/// moment it is released — so nothing here ever touches the system setting.
///
/// Native only, and never on a television: a set has its own backlight control
/// on its own remote, and the Android TV build would simply be told no.
///
/// **The values here are perceived brightness, not backlight.** 0.5 means "half
/// as bright as it can look", which is nowhere near half the backlight — see
/// [PerceivedBrightness]. Callers deal in what the eye reads; the conversion to
/// what the hardware is driven with happens at this boundary and nowhere else.
///
/// On iOS there is nothing to convert: `UIScreen.brightness` is the position of
/// the system's own slider, which already carries that curve. Applying ours on
/// top would curve it twice and crush the whole usable range into the bottom of
/// the bar — the exact fault it exists to remove, only worse.
abstract final class ScreenBrightnessControl {
  const ScreenBrightnessControl._();

  static bool get supported =>
      !AppPlatform.isWeb && AppPlatform.isMobile && !TvMode.isTv;

  /// Whether this platform's brightness value is linear in backlight, and so
  /// needs the curve put back. Android's window brightness is; iOS's is not.
  static bool get _needsCurve => AppPlatform.isAndroid;

  /// The override currently in force — in perceived brightness — or null when
  /// the screen is still on whatever the system chose.
  static double? _override;

  /// What the screen was showing before the player asked for anything, so the
  /// slider can open on the real value rather than jumping on first touch.
  static Future<double?> current() async {
    if (!supported) return null;
    final held = _override;
    if (held != null) return held;
    try {
      final value = (await ScreenBrightness().application).clamp(0.0, 1.0);
      return _needsCurve ? PerceivedBrightness.fromBacklight(value) : value;
    } catch (e) {
      // A device that refuses to report its brightness will refuse to set it
      // too; answering null is what tells the caller to leave the control out.
      debugPrint('Brightness: cannot read current value: $e');
      return null;
    }
  }

  /// Applies [value] (0..1, perceived) as this app's brightness override.
  static Future<void> set(double value) async {
    if (!supported) return;
    final v = value.clamp(0.0, 1.0);
    _override = v;
    final backlight = _needsCurve ? PerceivedBrightness.toBacklight(v) : v;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(backlight);
    } catch (e) {
      debugPrint('Brightness: cannot set $backlight: $e');
    }
  }

  /// Hands the screen back to the system setting.
  ///
  /// Called on the way out of the player — and it has to be, or a film watched
  /// at 10% would leave the phone that dark on the home screen, looking for all
  /// the world like a hardware fault.
  static Future<void> release() async {
    if (_override == null) return;
    _override = null;
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (e) {
      debugPrint('Brightness: cannot reset: $e');
    }
  }
}
