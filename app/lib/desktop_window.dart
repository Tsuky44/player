import 'package:flutter/material.dart';

import 'theme/app_colors.dart';
import 'theme/app_motion.dart';
import 'utils/app_platform.dart';
import 'utils/window_controls.dart';
import 'l10n/tr.dart';

/// Custom caption bar is Windows-only; macOS keeps native traffic lights.
bool get useDesktopCaptionBar => AppPlatform.isWindows;

/// Hidden native title bar (custom bar on Windows, traffic lights on macOS).
bool get useHiddenNativeTitleBar =>
    AppPlatform.isWindows || AppPlatform.isMacOS;

/// Vertical space for macOS traffic lights — UI controls sit just below.
double get macOSWindowControlsTopInset => AppPlatform.isMacOS ? 40 : 0;

/// Height of the desktop glass nav (≥900px), from the top of the window.
double shellHeaderHeight(BuildContext context) {
  const headerVerticalPadding = 16.0; // matches _DesktopGlassHeader (6 + 10)
  const navRowHeight = 44.0;
  return MediaQuery.paddingOf(context).top +
      macOSWindowControlsTopInset +
      headerVerticalPadding +
      navRowHeight;
}

/// Top padding for tab bodies when the desktop glass nav overlaps content (≥900px).
double embeddedShellContentTopInset(BuildContext context) {
  const gapBelowHeader = 12.0;
  return shellHeaderHeight(context) + gapBelowHeader;
}

/// Controls visibility of the custom desktop caption bar (Windows only).
final ValueNotifier<bool> showDesktopCaption =
    ValueNotifier<bool>(AppPlatform.isWindows);

/// Barre de titre maison de Windows, affichée tant que [showDesktopCaption]
/// est vrai. La zone vide déplace la fenêtre (double-clic : agrandir) et les
/// contrôles restent en haut à droite, dans l'ordre Windows, sous forme de
/// pastilles [WindowControlPills].
class WindowCaptionBar extends StatefulWidget {
  const WindowCaptionBar({super.key});

  /// Hauteur de la barre : juste de quoi loger les pastilles et rester
  /// saisissable à la souris pour déplacer la fenêtre.
  static const double height = 28;

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
      height: WindowCaptionBar.height,
      color: AppColors.surface,
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
          WindowControlPills(
            isMaximized: _isMaximized,
            onMinimize: WindowControls.minimize,
            onToggleMaximize: _toggleMaximize,
            onClose: WindowControls.close,
          ),
        ],
      ),
    );
  }
}

/// Les trois contrôles de fenêtre en pastilles façon macOS, gardés dans
/// l'ordre Windows : réduire, agrandir/restaurer, fermer tout à droite.
///
/// Comme sur macOS, les symboles n'apparaissent qu'au survol du groupe : au
/// repos, la barre ne montre que trois points de couleur.
class WindowControlPills extends StatefulWidget {
  final bool isMaximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  const WindowControlPills({
    super.key,
    required this.isMaximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  @override
  State<WindowControlPills> createState() => _WindowControlPillsState();
}

class _WindowControlPillsState extends State<WindowControlPills> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ControlPill(
              color: AppColors.warning,
              icon: Icons.remove_rounded,
              label: tr('Réduire'),
              showGlyph: _hovering,
              onPressed: widget.onMinimize,
            ),
            _ControlPill(
              color: AppColors.success,
              icon: widget.isMaximized
                  ? Icons.close_fullscreen_rounded
                  : Icons.add_rounded,
              label: widget.isMaximized ? tr('Restaurer') : tr('Agrandir'),
              showGlyph: _hovering,
              onPressed: widget.onToggleMaximize,
            ),
            _ControlPill(
              color: AppColors.error,
              icon: Icons.close_rounded,
              label: tr('Fermer'),
              showGlyph: _hovering,
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlPill extends StatelessWidget {
  /// Diamètre de la pastille, celui des contrôles de macOS.
  static const double _diameter = 12;

  /// Largeur cliquable : la pastille plus 4 px de chaque côté, sur toute la
  /// hauteur de la barre, pour ne pas avoir à viser un disque de 12 px.
  static const double _hitWidth = 20;

  final Color color;
  final IconData icon;
  final String label;
  final bool showGlyph;
  final VoidCallback onPressed;

  const _ControlPill({
    required this.color,
    required this.icon,
    required this.label,
    required this.showGlyph,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Pas de `Tooltip` : la barre vit au-dessus du Navigator, donc sans
    // Overlay, et un Tooltip y lève « No Overlay widget found ».
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: _hitWidth,
          height: WindowCaptionBar.height,
          child: Center(
            child: Container(
              width: _diameter,
              height: _diameter,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: AnimatedOpacity(
                opacity: showGlyph ? 1 : 0,
                duration: AppMotion.fade(context, AppMotion.micro),
                curve: AppMotion.curve,
                child: Icon(
                  icon,
                  size: 9,
                  color: Colors.black.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
