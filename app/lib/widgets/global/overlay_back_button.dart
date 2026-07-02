import 'package:flutter/material.dart';
import '../../desktop_window.dart';

/// Floating back control for detail screens — sits below macOS traffic lights.
class OverlayBackButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const OverlayBackButton({super.key, this.onPressed});

  static const double _buttonSize = 48;

  static double get leadingWidth => _buttonSize;

  static double get toolbarHeight => kToolbarHeight + macOSWindowControlsTopInset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _buttonSize,
      height: toolbarHeight,
      child: Padding(
        padding: EdgeInsets.only(top: macOSWindowControlsTopInset),
        child: Align(
          alignment: Alignment.topLeft,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: _buttonSize, height: _buttonSize),
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
