import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../desktop_window.dart';
import '../../utils/app_platform.dart';

/// Floating back control for detail screens — sits below macOS traffic lights
/// or below the status bar / notch on mobile.
class OverlayBackButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const OverlayBackButton({super.key, this.onPressed});

  static const double _buttonSize = 48;

  static double get leadingWidth => _buttonSize;

  static double toolbarHeightFor(BuildContext context) {
    final top = _topInset(context);
    return kToolbarHeight + top;
  }

  /// The window's own controls on macOS, or whatever the screen reserves at
  /// the top — the status bar, or the app's nav bar when the page opens
  /// under it (see `MainShell`). The larger wins: on macOS under the nav bar,
  /// the padding already includes the traffic lights.
  static double _topInset(BuildContext context) {
    final padding = MediaQuery.paddingOf(context).top;
    return AppPlatform.isMacOS
        ? math.max(macOSWindowControlsTopInset, padding)
        : padding;
  }

  static double get toolbarHeight =>
      kToolbarHeight + macOSWindowControlsTopInset;

  @override
  Widget build(BuildContext context) {
    final topInset = _topInset(context);

    return SizedBox(
      width: _buttonSize,
      height: kToolbarHeight + topInset,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Align(
          alignment: Alignment.topLeft,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: _buttonSize,
              height: _buttonSize,
            ),
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
            onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }
}
