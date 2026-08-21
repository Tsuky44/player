import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_platform.dart';

/// Which hardware decoding path libmpv is asked for.
///
/// Android is where this matters, and where it cannot simply be hardcoded.
///
/// `mediacodec` decodes into a buffer the GPU already owns and hands it
/// straight to the video output — the frame never touches the CPU. That is what
/// a set-top player does, and it is the difference between a 4K film playing on
/// a streaming stick and not. `mediacodec-copy` decodes in hardware too, then
/// copies every frame back into system memory so the renderer can upload it
/// again: correct everywhere, and on a 4K frame it is tens of megabytes of
/// memory traffic per second on the weakest CPU in the house.
///
/// The zero-copy path depends on the device's own MediaCodec and its driver,
/// and Android vendors do not all get it right — a bad one gives a green or
/// black picture with perfect sound. That failure cannot be detected from here
/// (the frames are opaque, and mpv reports them as decoded and displayed), so
/// it is a setting rather than a guess: the default takes the fast path, and
/// anyone whose box is one of the broken ones has a way out that is not a new
/// build of the app.
enum HardwareDecodingPreference {
  /// Zero copy where the platform supports it.
  auto,

  /// Hardware decode, frames copied back to system memory. The compatible one.
  copy,

  /// No hardware decoding at all. Software decode of anything above 1080p will
  /// not keep up on a television, but it is the one path that always draws.
  off,
}

/// Resolves the `hwdec` value mpv is given.
abstract final class HardwareDecoding {
  static const String _preferenceKey = 'hwdec_preference';

  static HardwareDecodingPreference _preference = HardwareDecodingPreference.auto;

  static HardwareDecodingPreference get preference => _preference;

  /// Reads the stored preference. Call once at startup, before a media opens.
  static Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_preferenceKey);
      _preference = HardwareDecodingPreference.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => HardwareDecodingPreference.auto,
      );
    } catch (_) {
      _preference = HardwareDecodingPreference.auto;
    }
  }

  static Future<void> setPreference(HardwareDecodingPreference value) async {
    _preference = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, value.name);
  }

  /// The `hwdec` option for this platform and preference.
  ///
  /// The two non-auto values are Android-shaped, because Android is the only
  /// platform whose hardware path is a lottery. Elsewhere they still mean what
  /// they say — copy back, or do not decode in hardware — using that platform's
  /// own spelling.
  static String get mpvValue => resolve(
        preference: _preference,
        isAndroid: AppPlatform.isAndroid,
        isMacOS: AppPlatform.isMacOS,
      );

  /// The platform-by-platform mapping, as a pure function so it can be checked
  /// for a platform other than the one the tests happen to run on.
  static String resolve({
    required HardwareDecodingPreference preference,
    required bool isAndroid,
    required bool isMacOS,
  }) {
    switch (preference) {
      case HardwareDecodingPreference.off:
        return 'no';
      case HardwareDecodingPreference.copy:
        if (isAndroid) return 'mediacodec-copy';
        if (isMacOS) return 'videotoolbox-copy';
        return 'auto-copy-safe';
      case HardwareDecodingPreference.auto:
        // Android: the zero-copy path, explicitly. `auto-safe` leaves the choice
        // to mpv's whitelist, which is conservative by design and is why a
        // frame the hardware had already decoded was being copied back through
        // the CPU on the devices least able to afford it.
        if (isAndroid) return 'mediacodec';
        // macOS 27 beta: plain VideoToolbox can freeze the video while audio
        // continues; the copy is compatible with the CVPixelBuffer/Metal path.
        // The two settings deliberately coincide there.
        if (isMacOS) return 'videotoolbox-copy';
        return 'auto-safe';
    }
  }

  static String describe() => '${_preference.name} → $mpvValue';

  @visibleForTesting
  static void overrideWith(HardwareDecodingPreference value) =>
      _preference = value;
}
