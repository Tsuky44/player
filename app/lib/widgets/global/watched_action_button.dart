import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

class WatchedActionButton extends StatelessWidget {
  final bool isWatched;
  final bool isLoading;
  final VoidCallback? onPressed;
  final bool compact;

  const WatchedActionButton({
    super.key,
    required this.isWatched,
    this.isLoading = false,
    this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = isWatched ? 'Marquer non vu' : 'Marquer vu';
    final icon = isWatched ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded;

    if (compact) {
      return IconButton(
        tooltip: label,
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                icon,
                color: isWatched ? AppColors.success : AppColors.textSecondary,
              ),
      );
    }

    return OutlinedButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: isWatched ? AppColors.success : AppColors.textPrimary,
        side: BorderSide(
          color: isWatched
              ? AppColors.success.withValues(alpha: 0.5)
              : AppColors.textSecondary,
        ),
      ),
    );
  }
}
