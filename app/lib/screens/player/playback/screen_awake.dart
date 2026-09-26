import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../utils/app_platform.dart';

/// Garde l'écran allumé pendant une lecture sur un appareil Apple.
///
/// Ni l'économiseur d'écran de tvOS ni la mise en veille d'un iPhone ou d'un
/// Mac ne savent qu'une vue Flutter est un film : sans ça, l'écran s'éteint au
/// milieu de la lecture. mpv l'avait par le widget `Video` de media_kit ;
/// ExoPlayer le fait lui-même sur Android.
abstract final class ScreenAwake {
  /// Le canal de l'hôte tvOS (`tvos/Runner/AppDelegate.swift`).
  static const MethodChannel _device = MethodChannel('onyx/device');

  static Future<void> set(bool on) async {
    try {
      // wakelock_plus n'a pas de portage tvOS : l'hôte le fait lui-même.
      if (AppPlatform.isTvOS) {
        await _device.invokeMethod<void>('setKeepScreenOn', on);
      } else {
        await WakelockPlus.toggle(enable: on);
      }
    } catch (_) {
      // Un hôte sans ce canal : l'écran s'éteindra, la lecture continuera.
    }
  }
}
