import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_platform.dart';

/// Native implementation of the window facade — see `window_controls.dart`.
///
/// Every method is a no-op on the platforms that have no window (Android, iOS),
/// so callers never need to pair a call with a platform check.
abstract final class WindowControls {
  /// Sizes, centres and shows the OS window. Called once, before `runApp`.
  static Future<void> initializeDesktopWindow({
    required bool hiddenTitleBar,
    required bool showWindowButtons,
  }) async {
    if (!AppPlatform.isDesktop) return;

    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle:
          hiddenTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: showWindowButtons,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  /// Whether the OS window is currently full screen. Always false where there
  /// is no window to ask.
  static Future<bool> isFullScreen() async {
    if (!AppPlatform.isDesktop) return false;
    return windowManager.isFullScreen();
  }

  static Future<void> setFullScreen(bool value) async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.setFullScreen(value);
  }

  static Future<bool> isMaximized() async {
    if (!AppPlatform.isDesktop) return false;
    return windowManager.isMaximized();
  }

  static Future<void> maximize() async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.maximize();
  }

  static Future<void> unmaximize() async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.unmaximize();
  }

  static Future<void> minimize() async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.minimize();
  }

  static Future<void> close() async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.close();
  }

  static Future<void> startDragging() async {
    if (!AppPlatform.isDesktop) return;
    await windowManager.startDragging();
  }
}

/// Region that moves the OS window when dragged. Transparent passthrough where
/// there is no window.
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!AppPlatform.isDesktop) return child;
    return DragToMoveArea(child: child);
  }
}
