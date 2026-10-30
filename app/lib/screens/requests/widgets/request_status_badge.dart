import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';

/// Le surtitre de statut de la fiche, comme OnyxHub
/// (`MediaAvailabilityBadges`) : capitales serrées, fond teinté à 15 %.
class RequestAvailabilityBadge extends StatelessWidget {
  final RequestMediaStatus status;

  /// Demandé mais pas encore sorti : pastille blanche.
  final bool awaitingRelease;

  const RequestAvailabilityBadge({
    super.key,
    required this.status,
    this.awaitingRelease = false,
  });

  @override
  Widget build(BuildContext context) {
    final (label, tint) = switch (status) {
      RequestMediaStatus.unknown => (null, AppColors.textPrimary),
      _ when awaitingRelease => (
          tr('Demandé · en attente de sortie'),
          AppColors.textPrimary
        ),
      RequestMediaStatus.available => (tr('Disponible'), AppColors.success),
      RequestMediaStatus.partial => (
          tr('Partiellement disponible'),
          AppColors.warning
        ),
      RequestMediaStatus.pending || RequestMediaStatus.processing => (
          tr('Demandé'),
          AppColors.warning
        ),
    };
    if (label == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: tint,
          fontSize: AppType.micro,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

/// Pastille d'état d'une saison, comme MediaHub (`SeasonStatusBadges`) : sa
/// disponibilité et, tant qu'elle n'est pas complète, le nombre d'épisodes
/// encore à venir ([remaining]).
class RequestStatusBadge extends StatelessWidget {
  final RequestMediaStatus status;
  final int? remaining;

  const RequestStatusBadge({super.key, required this.status, this.remaining});

  @override
  Widget build(BuildContext context) {
    final left = remaining;
    return switch (status) {
      RequestMediaStatus.available => _SeasonBadge(
          label: tr('Disponible'),
          icon: AppIcons.check,
          foreground: AppColors.success,
        ),
      RequestMediaStatus.partial => _SeasonBadge(
          label: left == null
              ? tr('Partiellement disponible')
              : '${tr('Partiellement disponible')} · ${_remaining(left)}',
          icon: AppIcons.check,
          foreground: AppColors.warning,
        ),
      RequestMediaStatus.pending ||
      RequestMediaStatus.processing =>
        _SeasonBadge(
          label: left == null ? tr('En attente') : _remaining(left),
          icon: AppIcons.schedule,
          foreground: AppColors.warning,
        ),
      RequestMediaStatus.unknown => const SizedBox.shrink(),
    };
  }
}

String _remaining(int n) =>
    n == 1 ? tr('1 épisode restant') : tr('{0} restants', [n]);

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
              fontSize: AppType.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
