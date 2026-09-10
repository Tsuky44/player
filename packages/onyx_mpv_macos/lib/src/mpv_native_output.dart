import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// La sortie vidéo de mpv quand il dessine dans une `MpvHostView`.
///
/// Les options passent par ici dans l'ordre où elles sont demandées, et
/// chacune n'est rendue qu'une fois que mpv l'a appliquée : c'est ce qui
/// permet de libérer une vue en sachant que mpv n'y dessine plus.
///
/// Chaque appel part d'un isolate à part. Changer `vo` reconstruit la sortie
/// vidéo, et sur macOS cette reconstruction attend le thread principal. Si le
/// thread de l'interface restait bloqué dessus, un redimensionnement de
/// fenêtre au même moment — qui fait attendre le thread principal sur celui de
/// l'interface — suffirait à tout figer.
final class MpvNativeOutput {
  MpvNativeOutput({required this.libmpvPath, required this.mpvHandle});

  /// Le libmpv que media_kit a chargé : même bibliothèque, même instance.
  final String libmpvPath;

  /// L'adresse du `mpv_handle` (`Player.handle` de media_kit).
  final int mpvHandle;

  int? _attachedView;
  Future<void> _queue = Future.value();

  /// Fait dessiner mpv dans cette vue. `wid` avant `vo` : mpv ne lit `wid`
  /// qu'à la création de sa sortie vidéo.
  Future<void> attach(int viewHandle) => _enqueue(() async {
        await _set('wid', '$viewHandle');
        await _set('vo', 'gpu-next');
        _attachedView = viewHandle;
      });

  /// Reprend la vue à mpv s'il y dessine encore. Une vue déjà remplacée par
  /// une autre entre-temps n'est pas touchée.
  Future<void> detach(int viewHandle) => _enqueue(() async {
        if (_attachedView != viewHandle) return;
        await _set('vo', 'null');
        _attachedView = null;
      });

  Future<void> setProperty(String name, String value) =>
      _enqueue(() => _set(name, value));

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.catchError((Object error) {
      debugPrint('MpvNativeOutput: $error');
    });
    return result;
  }

  Future<void> _set(String name, String value) async {
    final library = libmpvPath;
    final handle = mpvHandle;
    final code = await Isolate.run(
      () => _setPropertyString(library, handle, name, value),
    );
    if (code < 0) {
      throw StateError('mpv a refusé $name=$value (erreur $code)');
    }
  }
}

int _setPropertyString(
  String libmpvPath,
  int handle,
  String name,
  String value,
) {
  final setProperty = DynamicLibrary.open(libmpvPath).lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>(
    'mpv_set_property_string',
  );
  final nativeName = name.toNativeUtf8();
  final nativeValue = value.toNativeUtf8();
  try {
    return setProperty(Pointer.fromAddress(handle), nativeName, nativeValue);
  } finally {
    malloc.free(nativeName);
    malloc.free(nativeValue);
  }
}
