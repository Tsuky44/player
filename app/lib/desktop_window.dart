import 'package:flutter/material.dart';

import 'utils/app_platform.dart';
import 'utils/window_controls.dart';

/// Custom caption bar is Windows-only; macOS keeps native traffic lights.
bool get useDesktopCaptionBar => AppPlatform.isWindows;

/// Hidden native title bar (custom bar on Windows, traffic lights on macOS).
bool get useHiddenNativeTitleBar =>
    AppPlatform.isWindows || AppPlatform.isMacOS;

/// Vertical space for macOS traffic lights — UI controls sit just below.
double get macOSWindowControlsTopInset => AppPlatform.isMacOS ? 40 : 0;

/// Top padding for tab bodies when the desktop glass nav overlaps content (≥900px).
double embeddedShellContentTopInset(BuildContext context) {
  const headerVerticalPadding = 16.0; // matches _DesktopGlassHeader (6 + 10)
  const navRowHeight = 44.0;
  const gapBelowHeader = 12.0;
  return MediaQuery.paddingOf(context).top +
      macOSWindowControlsTopInset +
      headerVerticalPadding +
      navRowHeight +
      gapBelowHeader;
}

/// Controls visibility of the custom desktop caption bar (Windows only).
final ValueNotifier<bool> showDesktopCaption =
    ValueNotifier<bool>(AppPlatform.isWindows);

/// Windows-style caption bar shown at the top of desktop windows when
/// [showDesktopCaption] is true. Provides minimize, maximize/restore
/// and close buttons, and the empty area can be dragged to move the window.
class WindowCaptionBar extends StatefulWidget {
  const WindowCaptionBar({super.key});

  @override
  State<WindowCaptionBar> createState() => _WindowCaptionBarState();
}

class _WindowCaptionBarState extends State<WindowCaptionBar> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _syncMaximized();
  }

  Future<void> _syncMaximized() async {
    if (!useDesktopCaptionBar) return;
    final maximized = await WindowControls.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  Future<void> _toggleMaximize() async {
    if (_isMaximized) {
      await WindowControls.unmaximize();
    } else {
      await WindowControls.maximize();
    }
    await _syncMaximized();
  }

  @override
  Widget build(BuildContext context) {
    if (!useDesktopCaptionBar) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 40,
      color: const Color(0xFF1F1F1F),
      child: Row(
        children: [
          // Draggable / double-tap area (empty space only)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => WindowControls.startDragging(),
              onDoubleTap: _toggleMaximize,
              child: const SizedBox.expand(),
            ),
          ),
          _CaptionButton(
            icon: Icons.remove,
            tooltip: 'Réduire',
            onPressed: () => WindowControls.minimize(),
          ),
          _CaptionButton(
            icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
            tooltip: _isMaximized ? 'Restaurer' : 'Agrandir',
            onPressed: _toggleMaximize,
          ),
          _CaptionButton(
            icon: Icons.close,
            tooltip: 'Fermer',
            onPressed: () => WindowControls.close(),
            hoverColor: Colors.redAccent,
            iconColor: Colors.white,
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? hoverColor;
  final Color? iconColor;

  const _CaptionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.hoverColor,
    this.iconColor,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 40,
          color: _hovering
              ? (widget.hoverColor ?? Colors.white.withOpacity(0.1))
              : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            color: widget.iconColor ?? Colors.white.withOpacity(0.85),
            size: 18,
          ),
        ),
      ),
    );
  }
}
