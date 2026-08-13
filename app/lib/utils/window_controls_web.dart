import 'package:flutter/material.dart';

/// Web implementation of the window facade — see `window_controls.dart`.
///
/// A browser tab has no window to size, drag or close, so every operation is a
/// no-op. Full screen on the web is a different mechanism entirely (the
/// Fullscreen API, which iPhone Safari does not implement for arbitrary
/// elements) and is handled by the player rather than here.
abstract final class WindowControls {
  static Future<void> initializeDesktopWindow({
    required bool hiddenTitleBar,
    required bool showWindowButtons,
  }) async {}

  static Future<bool> isFullScreen() async => false;
  static Future<void> setFullScreen(bool value) async {}

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
