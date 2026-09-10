import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Implémentation native de `MpvNativeView` — voir `mpv_native_view.dart`.
abstract final class MpvNativeView {
  /// Un libmpv désigné au lancement, pour en essayer un autre que l'installé.
  static const String _override = String.fromEnvironment('ONYX_LIBMPV');

  /// Là où `build_libmpv.sh` installe le libmpv patché.
  static String get installedPath =>
      '${Platform.environment['HOME'] ?? ''}'
      '/Library/Application Support/Onyx/libmpv/libmpv.2.dylib';

  static String? _libmpvPath;

  /// Le libmpv patché retenu, ou null quand media_kit garde le sien.
  static String? get libmpvPath => _libmpvPath;

  static bool get enabled => _libmpvPath != null;

  /// À appeler une fois, avant `MediaKit.ensureInitialized`.
  static void resolve() {
    if (!Platform.isMacOS) return;
    _libmpvPath = pick(
      [if (_override.isNotEmpty) _override, installedPath],
      _canLoad,
    );
    debugPrint('MpvNativeView: '
        '${_libmpvPath ?? 'aucun libmpv patché, texture de media_kit'}');
  }

  /// Le premier candidat qui se charge.
  ///
  /// Un binaire qui ne se charge pas — une dépendance Homebrew absente, un Mac
  /// Intel face à un build arm64 — ne doit pas empêcher l'app de démarrer :
  /// l'app retombe alors sur la texture de media_kit.
  @visibleForTesting
  static String? pick(
    List<String> candidates,
    bool Function(String path) canLoad,
  ) {
    for (final path in candidates) {
      if (canLoad(path)) return path;
    }
    return null;
  }

  static bool _canLoad(String path) {
    if (!File(path).existsSync()) return false;
    try {
      DynamicLibrary.open(path);
      return true;
    } catch (e) {
      debugPrint('MpvNativeView: $path ne se charge pas ($e)');
      return false;
    }
  }
}
