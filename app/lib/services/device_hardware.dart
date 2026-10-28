import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_platform.dart';

/// Ce que l'appareil dit de sa mémoire et de son modèle, demandé une fois.
///
/// Deux lecteurs en ont besoin : [PlaybackProfiles] pour la taille des
/// tampons, et `LiteMode` pour décider si l'interface s'allège. Une seule
/// question au canal `onyx/device`, posée ici.
abstract final class DeviceHardware {
  static const MethodChannel _channel = MethodChannel('onyx/device');

  static int _totalMemoryMb = 0;
  static bool _isLowRamDevice = false;
  static String _model = '';
  static Future<void>? _pending;

  /// La mémoire vive totale, en Mo. 0 quand la plateforme n'a pas répondu.
  static int get totalMemoryMb => _totalMemoryMb;

  /// Le drapeau `isLowRamDevice` d'Android, faux ailleurs.
  static bool get isLowRamDevice => _isLowRamDevice;

  /// L'identifiant matériel Apple (`AppleTV5,3`), vide ailleurs.
  static String get model => _model;

  /// Interroge la plateforme. Appelable plusieurs fois ; seul le premier appel
  /// travaille, les suivants attendent la même réponse.
  static Future<void> initialize() => _pending ??= _query();

  static Future<void> _query() async {
    if (!AppPlatform.isAndroid && !AppPlatform.isIOS && !AppPlatform.isTvOS) {
      return;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'memoryProfile',
      );
      _totalMemoryMb = (raw?['totalMemoryMb'] as num?)?.toInt() ?? 0;
      _isLowRamDevice = raw?['isLowRamDevice'] as bool? ?? false;
      _model = raw?['model'] as String? ?? '';
    } catch (error) {
      // Un hôte plus ancien que ce canal : chaque lecteur a son repli pour une
      // mémoire inconnue.
      debugPrint('DeviceHardware: memory query unavailable ($error)');
    }
  }

  @visibleForTesting
  static void overrideForTest({
    int totalMemoryMb = 0,
    bool isLowRamDevice = false,
    String model = '',
  }) {
    _totalMemoryMb = totalMemoryMb;
    _isLowRamDevice = isLowRamDevice;
    _model = model;
    _pending = Future.value();
  }

  @visibleForTesting
  static void resetForTest() {
    _totalMemoryMb = 0;
    _isLowRamDevice = false;
    _model = '';
    _pending = null;
  }
}
