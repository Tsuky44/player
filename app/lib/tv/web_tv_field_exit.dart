import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_platform.dart';
import 'tv_deferred_keyboard.dart';
import 'tv_mode.dart';

/// Les flèches font sortir d'un champ texte, sur un téléviseur piloté par un
/// navigateur (LG, ADR-0076 : haut et bas), sur Android TV et sur Apple TV
/// (les quatre).
///
/// [TvDeferredKeyboard] rend un champ à la télécommande quand le clavier se
/// referme et que le champ perd le focus. Sur webOS, il le garde : le clavier
/// virtuel se ferme, la page ne le voit pas. Android TV aussi le garde quand
/// Retour ferme son clavier (Gboard, Android 16), sans rien en signaler à
/// l'app. Et dans un champ, les flèches déplacent le curseur : la
/// télécommande restait prisonnière du premier champ ouvert. Sur une ligne,
/// elles relâchent donc le champ, et [TvDeferredKeyboard] rend le focus à son
/// cadre ; sur Android TV et Apple TV, le pas demandé suit dans la foulée.
abstract final class WebTvFieldExit {
  static bool _installed = false;

  /// Branché une fois, avant le système de focus : les raccourcis de Flutter
  /// Web qui donnent les flèches au navigateur passeraient sinon d'abord.
  static void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addEarlyKeyEventHandler(_handle);
  }

  /// Remplace la plateforme dans les tests, qui ne tournent ni sur Android
  /// TV ni sur Apple TV : vrai pour un clavier qui garde la télécommande tant
  /// qu'il est ouvert.
  @visibleForTesting
  static bool? debugKeyboardOwnsRemote;

  @visibleForTesting
  static void debugUninstall() {
    if (!_installed) return;
    _installed = false;
    FocusManager.instance.removeEarlyKeyEventHandler(_handle);
  }

  static KeyEventResult _handle(KeyEvent event) {
    if (!TvMode.isTv) return KeyEventResult.ignored;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    // Sur Android TV et Apple TV, le clavier ouvert garde la télécommande
    // pour lui (le pavé, le trackpad) : une flèche qui arrive ici veut dire
    // qu'il est fermé, et le curseur n'a plus rien à faire dans le texte.
    // Sur webOS, gauche et droite restent au texte.
    final keyboardOwnsRemote = debugKeyboardOwnsRemote ??
        (AppPlatform.isAndroid || AppPlatform.isTvOS);
    final horizontal = direction == TraversalDirection.left ||
        direction == TraversalDirection.right;
    if (horizontal && !keyboardOwnsRemote) return KeyEventResult.ignored;
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
        // Et le pas demandé, dans la foulée : sans lui, le premier appui ne
        // faisait que poser l'anneau sur le cadre du champ. Après la
        // microtâche qui applique ce focus.
        if (keyboardOwnsRemote) {
          Future.microtask(
              () => FocusManager.instance.primaryFocus?.focusInDirection(
                    direction,
                  ));
        }
      } else {
        focus.unfocus();
      }
    }
    return KeyEventResult.handled;
  }
}
