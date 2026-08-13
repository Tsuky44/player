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
    final top = AppPlatform.isMacOS
        ? macOSWindowControlsTopInset
        : MediaQuery.paddingOf(context).top;
    return kToolbarHeight + top;
  }

  static double get toolbarHeight =>
      kToolbarHeight + macOSWindowControlsTopInset;

  @override
  Widget build(BuildContext context) {
    final topInset = AppPlatform.isMacOS
        ? macOSWindowControlsTopInset
        : MediaQuery.paddingOf(context).top;

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
