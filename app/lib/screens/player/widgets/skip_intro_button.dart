import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

class SkipIntroButton extends StatelessWidget {
  final VoidCallback onSkip;

  const SkipIntroButton({super.key, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 170,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSkip,
          borderRadius: BorderRadius.circular(12),
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
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Passer l'intro",
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(width: 8),
                    Icon(
                      Icons.skip_next_rounded,
                      color: AppColors.textPrimary,
                      size: 20,
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
