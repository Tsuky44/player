import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../utils/app_platform.dart';
import '../tv/tv_mode.dart';

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
abstract final class ScreenBrightnessControl {
  const ScreenBrightnessControl._();

  static bool get supported =>
      !AppPlatform.isWeb && AppPlatform.isMobile && !TvMode.isTv;

  /// The override currently in force, or null when the screen is still on
  /// whatever the system chose.
  static double? _override;

  /// What the screen was showing before the player asked for anything, so the
  /// slider can open on the real value rather than jumping on first touch.
  static Future<double?> current() async {
    if (!supported) return null;
    final held = _override;
    if (held != null) return held;
    try {
      return (await ScreenBrightness().application).clamp(0.0, 1.0);
    } catch (e) {
      // A device that refuses to report its brightness will refuse to set it
      // too; answering null is what tells the caller to leave the control out.
      debugPrint('Brightness: cannot read current value: $e');
      return null;
    }
  }

  /// Applies [value] (0..1) as this app's brightness override.
  static Future<void> set(double value) async {
    if (!supported) return;
    final v = value.clamp(0.0, 1.0);
    _override = v;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(v);
    } catch (e) {
      debugPrint('Brightness: cannot set $v: $e');
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
