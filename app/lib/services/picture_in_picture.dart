import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../tv/tv_mode.dart';
import '../utils/app_platform.dart';

/// The film in a corner of the home screen, while the phone is used for
/// something else.
///
/// **Android only, and that is not an omission.** The system window is created
/// by the platform, not by the app: on Android the activity asks for it and the
/// same Flutter view is simply drawn smaller, which is why the picture and the
/// sound carry on without interruption. iOS has the same feature and it is a
/// different mechanism — `AVPictureInPictureController` puts an *AVFoundation
/// layer* on screen, and this player renders through mpv into a Flutter
/// texture, which is not one. Reaching it there would mean handing decoded
/// frames to an `AVSampleBufferDisplayLayer`, or playing through `AVPlayer` —
/// which the ADR-0011 ruled out, because it refuses MKV and much of a private
/// library is MKV.
///
/// The window is *armed* rather than opened: Android only lets it be created at
/// the instant the user leaves, so the shape is handed over in advance and the
/// system does the rest — on Android 12 and up, with the animation that carries
/// the picture into the corner.
abstract final class PictureInPicture {
  const PictureInPicture._();

  static const MethodChannel _channel = MethodChannel('onyx/device');

  /// Whether the platform can do it at all. False until [initialize] has asked.
  static bool get supported => _supported;
  static bool _supported = false;

  /// True while the film is playing in the little window.
  ///
  /// The interface listens: in that window there is no room for chrome, and
  /// nothing to tap it with.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Raised when the window is closed rather than restored — the film has
  /// nowhere left to play and the player has to let go.
  static final ValueNotifier<int> closed = ValueNotifier<int>(0);

  /// Asked once, at startup, and the answers wired up.
  static Future<void> initialize() async {
    if (!_canAsk) return;
    _channel.setMethodCallHandler(_onPlatformCall);
    try {
      _supported =
          await _channel.invokeMethod<bool>('supportsPictureInPicture') ?? false;
    } catch (error) {
      debugPrint('Picture-in-picture: unavailable ($error)');
      _supported = false;
    }
  }

  /// Arms the window for a film of [width] × [height] pixels, or disarms it
  /// when either is zero — leaving the player, or a film that has not said how
  /// big it is yet.
  static Future<void> arm({required int width, required int height}) async {
    if (!_supported) return;
    final shape = shapeFor(width, height);
    try {
      await _channel.invokeMethod<bool>('setPictureInPicture', <String, int>{
        'width': shape.$1,
        'height': shape.$2,
      });
    } catch (error) {
      debugPrint('Picture-in-picture: cannot arm ($error)');
    }
  }

  static Future<void> disarm() => arm(width: 0, height: 0);

  /// The shape the little window may take, which is not always the film's.
  ///
  /// Android refuses an aspect ratio outside 1:2.39 … 2.39:1 — it throws rather
  /// than clamping — and 2.39:1 is exactly the shape of a scope film. So the
  /// ratio is brought inside the range here, and the last of the picture is
  /// left slightly letterboxed in the corner rather than not shown at all.
  static (int, int) shapeFor(int width, int height) {
    if (width <= 0 || height <= 0) return (0, 0);
    final ratio = width / height;
    // Rounded down in both directions, and that is the whole subtlety: rounding
    // to the nearest lands a hair *outside* the range as often as inside, and
    // Android does not forgive a hair — it throws. Down makes a wide picture
    // narrower and a tall one shorter, which is inside either way.
    if (ratio > _maxRatio) return ((height * _maxRatio).floor(), height);
    if (ratio < 1 / _maxRatio) return (width, (width * _maxRatio).floor());
    return (width, height);
  }

  /// Android's own limit, both ways up.
  static const double _maxRatio = 2.39;

  /// A television has its own idea of this, and the chrome here is not built
  /// for it; a desktop has windows already.
  static bool get _canAsk =>
      AppPlatform.isAndroid && !AppPlatform.isWeb && !TvMode.isTv;

  static Future<dynamic> _onPlatformCall(MethodCall call) async {
    if (call.method != 'pictureInPictureChanged') return null;
    final arguments = (call.arguments as Map?)?.cast<String, dynamic>();
    active.value = arguments?['inPictureInPicture'] as bool? ?? false;
    if (arguments?['closed'] as bool? ?? false) closed.value++;
    return null;
  }
}
