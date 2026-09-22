import 'package:flutter/services.dart';

import '../utils/app_platform.dart';

/// Hands a downloaded APK to Android's own package installer — see the
/// `installApk`/`canInstallPackages`/`openInstallPermissionSettings` handlers
/// in `MainActivity.kt`, on the same `onyx/device` channel every other
/// Android-only capability in this app already uses.
///
/// Nothing here is silent: Android always shows its own install confirmation,
/// and — the first time, or after the setting is revoked — its "allow
/// installs from this source" screen first. This is as automatic as a
/// sideloaded app is allowed to get.
abstract final class AndroidApkInstaller {
  static const MethodChannel _channel = MethodChannel('onyx/device');

  /// False only means "ask the user first" — see [openInstallPermissionSettings].
  static Future<bool> canInstallPackages() async {
    if (!AppPlatform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the one settings screen that toggles "allow from this source" for
  /// this app specifically, instead of the general security settings list.
  static Future<void> openInstallPermissionSettings() async {
    if (!AppPlatform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } catch (_) {
      // Nothing to fall back to — the caller already explained why it asked.
    }
  }

  /// Launches the system installer over [apkPath]. Returns whether it could be
  /// *launched* — Android gives no callback for whether the user went through
  /// with the install itself.
  static Future<bool> install(String apkPath) async {
    if (!AppPlatform.isAndroid) return false;
    try {
      return await _channel
              .invokeMethod<bool>('installApk', {'path': apkPath}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
