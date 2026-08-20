import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_platform.dart';

/// What the user asked for, which is not always what the hardware says.
///
/// [auto] trusts the device. The two overrides exist for the cases detection
/// gets wrong in opposite directions: a no-name Android box that never
/// advertises leanback, and a tablet plugged into a dock that does.
enum TvModePreference { auto, on, off }

/// Whether this app instance is being driven by a remote control.
///
/// This is the single switch behind every television affordance: the focus
/// rings, the D-pad `select` binding, the QR sign-in instead of a password
/// form. It is read constantly and changes almost never, so it lives as a
/// [ValueNotifier] the root listens to once and republishes through [TvScope].
abstract final class TvMode {
  static const MethodChannel _channel = MethodChannel('onyx/device');

  static const String _preferenceKey = 'tv_mode_preference';

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static bool _detected = false;
  static TvModePreference _preference = TvModePreference.auto;
  static String _deviceName = 'Téléviseur';

  /// What the hardware itself reported, independent of the override.
  static bool get detected => _detected;

  static TvModePreference get preference => _preference;

  /// Label shown on the phone that approves a pairing, so the user can tell
  /// which screen in the house is asking to be signed in.
  static String get deviceName => _deviceName;

  /// True outside a widget tree — for code that has no [BuildContext].
  /// Inside one, prefer [TvScope.of] so the widget rebuilds when this changes.
  static bool get isTv => enabled.value;

  /// Resolves the mode once, at startup, before the first frame.
  ///
  /// Detection is best-effort by design: a device that fails to answer is
  /// treated as "not a TV", which is the mode that degrades gracefully — a
  /// television stuck in phone mode is still usable with a remote, whereas a
  /// phone stuck in TV mode loses its password form.
  static Future<void> initialize() async {
    _preference = await _readPreference();

    if (AppPlatform.isAndroid) {
      try {
        _detected = await _channel.invokeMethod<bool>('isTelevision') ?? false;
        final name = await _channel.invokeMethod<String>('deviceName');
        if (name != null && name.trim().isNotEmpty) {
          _deviceName = name.trim();
        }
      } catch (error) {
        // MissingPluginException on an older install of the host app, or a
        // platform that never registered the channel.
        debugPrint('TvMode: detection unavailable ($error)');
        _detected = false;
      }
    }

    _apply();
  }

  /// Applies an explicit override and persists it. Takes effect immediately:
  /// the root rebuilds off [enabled].
  static Future<void> setPreference(TvModePreference preference) async {
    _preference = preference;
    _apply();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, preference.name);
  }

  static void _apply() {
    enabled.value = _resolve();

    // Flutter picks its highlight mode from the last input it saw. On Android
    // that starts as `touch`, and in touch mode Material widgets paint no focus
    // state at all — the user moves the D-pad and nothing on screen changes,
    // which is the single most common way a Flutter app is unusable on a TV.
    // Pinning the traditional strategy keeps the rings on.
    //
    // Not reset on the way out: the strategy is self-correcting the moment a
    // real touch or pointer event arrives.
    if (enabled.value) {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
    }
  }

  static bool _resolve() {
    switch (_preference) {
      case TvModePreference.on:
        return true;
      case TvModePreference.off:
        return false;
      case TvModePreference.auto:
        return _detected;
    }
  }

  static Future<TvModePreference> _readPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_preferenceKey);
      return TvModePreference.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => TvModePreference.auto,
      );
    } catch (_) {
      return TvModePreference.auto;
    }
  }
}

/// Publishes [TvMode.enabled] into the tree.
///
/// Reading the notifier directly from a leaf would not rebuild it when the
/// setting flips; depending on this does. One listener at the root, one
/// rebuild, and every widget below sees the new mode.
class TvScope extends InheritedWidget {
  final bool isTv;

  const TvScope({super.key, required this.isTv, required super.child});

  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TvScope>();
    return scope?.isTv ?? false;
  }

  @override
  bool updateShouldNotify(TvScope oldWidget) => oldWidget.isTv != isTv;
}
