import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Implémentation native de `MpvNativeView` — voir `mpv_native_view.dart`.
abstract final class MpvNativeView {
  /// Un libmpv désigné au lancement, pour en essayer un autre que l'installé.
  static const String _override = String.fromEnvironment('ONYX_LIBMPV');

  /// Le libmpv livrable, embarqué dans l'app (`build_release.sh`).
  static String get bundledPath =>
      '${File(Platform.resolvedExecutable).parent.parent.path}'
      '/Frameworks/OnyxMpv.framework/OnyxMpv';

  /// Là où `build_libmpv.sh` installe le libmpv de développement.
  static String get installedPath =>
      '${Platform.environment['HOME'] ?? ''}'
      '/Library/Application Support/Onyx/libmpv/libmpv.2.dylib';

  /// Le libmpv que media_kit embarque sous Windows. Il n'a pas besoin de
  /// patch : mpv y sait déjà ouvrir sa propre fenêtre (ADR-0061).
  static const String _windowsLibmpv = 'libmpv-2.dll';

  static String? _libmpvPath;

  /// Le libmpv patché retenu, ou null quand media_kit garde le sien.
  static String? get libmpvPath => _libmpvPath;

  /// Le libmpv à travers lequel piloter la sortie vidéo de mpv, hors du
  /// thread de l'interface : le patché sur macOS, celui de media_kit sous
  /// Windows, où seule la sortie d'un Dolby Vision profil 5 passe par là.
  static String get outputLibraryPath => _libmpvPath ?? _windowsLibmpv;

  /// Si mpv dessine **toutes** les lectures dans une vue native — macOS avec
  /// un libmpv patché. Sous Windows, la fenêtre de mpv se décide par média.
  static bool get enabled => _libmpvPath != null;

  /// À appeler une fois, avant `MediaKit.ensureInitialized`.
  static void resolve() {
    if (!Platform.isMacOS) return;
    _libmpvPath = pick(
      [if (_override.isNotEmpty) _override, bundledPath, installedPath],
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
