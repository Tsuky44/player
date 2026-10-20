import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'webos_remote_keys.dart';

/// Réécrit les touches de la télécommande LG — voir `webos_remote_keys.dart`.
abstract final class WebOSRemote {
  static bool _installed = false;

  /// Écoute en phase de capture, sur la fenêtre : elle passe avant les
  /// écouteurs que Flutter pose sur sa propre vue, qui ne voient donc que
  /// l'événement réécrit. Idempotent.
  static void install() {
    if (_installed) return;
    _installed = true;
    final listener = _rewrite.toJS;
    final options = web.AddEventListenerOptions(capture: true);
    web.window.addEventListener('keydown', listener, options);
    web.window.addEventListener('keyup', listener, options);
  }

  static void _rewrite(web.KeyboardEvent event) {
    // L'événement que ce code a lui-même émis n'est pas « de confiance » :
    // sans ce filtre, il serait réécrit à son tour, indéfiniment.
    if (!event.isTrusted) return;
    final name = webOSRemoteKeyName(keyCode: event.keyCode, key: event.key);
    if (name == null) return;
    final target = event.target;
    if (target == null) return;

    // preventDefault aussi : webOS ferait sinon son propre geste de la touche
    // — Retour, sans `disableBackHistoryAPI`, recule dans l'historique de la
    // page et ramènerait au lanceur.
    event
      ..preventDefault()
      ..stopImmediatePropagation();
    target.dispatchEvent(web.KeyboardEvent(
      event.type,
      web.KeyboardEventInit(
        key: name,
        code: name,
        keyCode: event.keyCode,
        repeat: event.repeat,
        bubbles: true,
        cancelable: true,
        composed: true,
      ),
    ));
  }
}
