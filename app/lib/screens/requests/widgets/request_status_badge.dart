import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';

/// Hero availability pill — Quiet Premium semantic colors.
class RequestAvailabilityBadge extends StatelessWidget {
  final RequestMediaStatus status;

  const RequestAvailabilityBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      RequestMediaStatus.available => const _HeroBadge(
          label: 'Disponible',
          foreground: AppColors.success,
          background: AppColors.success,
          border: AppColors.success,
        ),
      RequestMediaStatus.partial => const _HeroBadge(
          label: 'Partiellement disponible',
          foreground: AppColors.warning,
          background: AppColors.warning,
          border: AppColors.warning,
        ),
      RequestMediaStatus.pending || RequestMediaStatus.processing =>
        const _HeroBadge(
          label: 'Demandé',
          foreground: AppColors.accentMuted,
          background: AppColors.primary,
          border: AppColors.primary,
        ),
      RequestMediaStatus.unknown => const SizedBox.shrink(),
    };
  }
}

class _HeroBadge extends StatelessWidget {
  final String label;
  final Color foreground;
  final Color background;
  final Color border;

  const _HeroBadge({
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: background.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Compact season-row badges.
class RequestStatusBadge extends StatelessWidget {
  final RequestMediaStatus status;

  const RequestStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      RequestMediaStatus.available => const _SeasonBadge(
          label: 'Disponible',
          icon: Icons.check_rounded,
          foreground: AppColors.success,
        ),
      RequestMediaStatus.partial => const _SeasonBadge(
          label: 'Partiellement disponible',
          icon: Icons.check_rounded,
          foreground: AppColors.warning,
        ),
      RequestMediaStatus.pending || RequestMediaStatus.processing =>
        const _SeasonBadge(
          label: 'En attente',
          icon: Icons.schedule_rounded,
          foreground: AppColors.accentMuted,
        ),
      RequestMediaStatus.unknown => const SizedBox.shrink(),
    };
  }
}

class _SeasonBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color foreground;

  const _SeasonBadge({
    required this.label,
    required this.icon,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
