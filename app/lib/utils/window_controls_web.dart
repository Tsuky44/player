import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Web implementation of the window facade — see `window_controls.dart`.
///
/// A browser tab has no window to size, drag or close, so those operations are
/// no-ops. Full screen is the exception: the tab can take the whole display
/// through the Fullscreen API.
abstract final class WindowControls {
  static Future<void> initializeDesktopWindow({
    required bool hiddenTitleBar,
    required bool showWindowButtons,
  }) async {}

  static Future<bool> isFullScreen() async =>
      web.document.fullscreenElement != null;

  /// Le plein écran porte sur la page entière et non sur la balise vidéo : le
  /// chrome et les sous-titres sont dessinés par Flutter par-dessus l'image
  /// (ADR-0031) et disparaîtraient avec le plein écran natif de `<video>`.
  ///
  /// Le navigateur refuse la demande hors d'un geste de l'utilisateur, et
  /// Safari sur iPhone n'implémente pas l'API pour un élément quelconque : dans
  /// les deux cas la page reste telle quelle, sans erreur à remonter.
  static Future<void> setFullScreen(bool value) async {
    try {
      if (value) {
        await web.document.documentElement?.requestFullscreen().toDart;
      } else if (web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      }
    } catch (_) {
      // Refus du navigateur ou API absente : voir le commentaire ci-dessus.
    }
  }

  static Future<bool> isMaximized() async => false;
  static Future<void> maximize() async {}
  static Future<void> unmaximize() async {}
  static Future<void> minimize() async {}
  static Future<void> close() async {}
  static Future<void> startDragging() async {}
}

/// No-op counterpart of the native drag region.
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
