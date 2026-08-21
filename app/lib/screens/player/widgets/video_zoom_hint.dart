import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// Transient label naming the display mode a pinch just landed on.
///
/// The gesture changes the shape of the picture, sometimes by cropping its
/// edges away, and does it without touching the chrome — so it needs to say
/// what it did. Netflix and YouTube both answer the same pinch the same way.
///
/// Placed above the middle rather than on it: the centre belongs to the
/// transport button, which may be up at the same time.
class VideoZoomHint extends StatelessWidget {
  /// The fit the picture has just been put into.
  final BoxFit fit;

  final bool visible;

  const VideoZoomHint({super.key, required this.fit, required this.visible});

  bool get _isCover => fit == BoxFit.cover;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.55),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          // In fast, out slow: the answer has to be legible the instant the
          // fingers land, and must not linger over the film afterwards.
          duration: Duration(milliseconds: visible ? 120 : 280),
          curve: Curves.easeOut,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: AppColors.surface.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.glassBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isCover
                          ? Icons.crop_free_rounded
                          : Icons.fit_screen_rounded,
                      color: AppColors.textPrimary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isCover ? 'Adaptatif' : 'Original',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
