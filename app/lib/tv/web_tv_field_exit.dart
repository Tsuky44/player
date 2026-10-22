import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'tv_deferred_keyboard.dart';
import 'tv_mode.dart';

/// Haut et bas font sortir d'un champ texte, sur un téléviseur piloté par un
/// navigateur (LG, ADR-0076).
///
/// [TvDeferredKeyboard] rend un champ à la télécommande quand le clavier se
/// referme, parce que sur Android le champ perd alors le focus. Sur webOS, il
/// le garde : le clavier virtuel se ferme, la page ne le voit pas. Et dans un
/// champ, Flutter Web laisse les flèches au navigateur, qui déplace le
/// curseur : la télécommande restait prisonnière du premier champ ouvert. Sur
/// une ligne, haut et bas n'ont rien à faire dans le texte ; ils relâchent donc
/// le champ, et [TvDeferredKeyboard] rend le focus à son cadre.
abstract final class WebTvFieldExit {
  static bool _installed = false;

  /// Branché une fois, avant le système de focus : les raccourcis de Flutter
  /// Web qui donnent les flèches au navigateur passeraient sinon d'abord.
  static void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addEarlyKeyEventHandler(_handle);
  }

  @visibleForTesting
  static void debugUninstall() {
    if (!_installed) return;
    _installed = false;
    FocusManager.instance.removeEarlyKeyEventHandler(_handle);
  }

  static KeyEventResult _handle(KeyEvent event) {
    if (!TvMode.isTv) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final editable = context?.findAncestorWidgetOfExactType<EditableText>();
    // Un texte sur plusieurs lignes a l'usage des flèches verticales.
    if (focus == null || editable == null || editable.maxLines != 1) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      final deferred =
          context!.findAncestorStateOfType<TvDeferredKeyboardState>();
      if (deferred != null) {
        deferred.releaseKeyboard();
      } else {
        focus.unfocus();
      }
    }
    return KeyEventResult.handled;
  }
}
