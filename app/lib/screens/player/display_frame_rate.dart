import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/app_platform.dart';

/// Asks the television to run at a rate the film divides into evenly.
///
/// A panel is 60 Hz and a film is 23.976 fps. Sixty does not divide by
/// twenty-four, so the player holds every second frame one vsync longer than
/// its neighbour — the 3:2 cadence. Nothing is dropped and nothing arrives
/// late; the picture simply moves in an uneven rhythm, and a slow pan makes it
/// impossible to miss. It reads exactly like "it is not smooth", and no amount
/// of decoder, buffer or network work touches it, because it is not a shortage
/// of anything.
///
/// This is the piece a set-top player has and a general-purpose app usually
/// does not. It only ever acts on a television — taking over the display mode
/// of a phone is not this app's business, and the panel there is not the source
/// of the problem anyway.
abstract final class DisplayFrameRate {
  static const MethodChannel _channel = MethodChannel('onyx/device');

  /// The rate currently requested, or null when the display is on its own.
  /// Exposed for the playback diagnostics line.
  static double? get requested => _requested;
  static double? _requested;

  /// Requests a mode whose refresh rate is a whole multiple of [fps].
  ///
  /// Returns the rate that was asked for, or null when nothing matched — a
  /// panel with a single 60 Hz mode is the common case, and there is nothing to
  /// be done about it from here.
  static Future<double?> matchTo(double fps) async {
    if (!AppPlatform.isAndroid || fps <= 0) return null;
    try {
      final rate = await _channel.invokeMethod<double>(
        'matchRefreshRate',
        {'fps': fps},
      );
      _requested = (rate == null || rate <= 0) ? null : rate;
      if (_requested != null) {
        debugPrint('DisplayFrameRate: ${fps.toStringAsFixed(3)} fps '
            '→ ${_requested!.toStringAsFixed(3)} Hz');
      }
      return _requested;
    } catch (error) {
      debugPrint('DisplayFrameRate: unavailable ($error)');
      return null;
    }
  }

  /// Gives the display back to the system. Must run when the player closes:
  /// the rest of the app is not 24 fps, and leaving the panel at a film's rate
  /// makes every scroll in the catalogue judder instead.
  static Future<void> release() async {
    if (!AppPlatform.isAndroid) return;
    _requested = null;
    try {
      await _channel.invokeMethod<void>('releaseRefreshRate');
    } catch (_) {
      // Nothing was ever taken if the call is not there.
    }
  }
}
