import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/poster_card.dart';

class RequestMediaCard extends StatelessWidget {
  final RequestMediaItem item;
  final VoidCallback onTap;
  final bool showTypeBadge;

  const RequestMediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.showTypeBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    return PosterCard(
      posterUrl: cardPosterUrl(item.posterUrl),
      title: item.title,
      subtitle: [
        if (item.year != null) item.year!,
        if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}',
      ].join('  •  '),
      onTap: onTap,
      overlays: [
        if (showTypeBadge)
          Positioned(top: 8, left: 8, child: _TypeBadge(type: item.mediaType)),
        if (item.status != RequestMediaStatus.unknown)
          Positioned(top: 8, right: 8, child: _StatusDot(status: item.status)),
      ],
    );
  }
}

/// Subtle glass pill — MediaHub MediaCardOverlay style.
class _TypeBadge extends StatelessWidget {
  final RequestMediaType type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        type == RequestMediaType.movie ? 'Film' : 'Série',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// Colored status bubble — MediaHub MediaCardStatus style.
class _StatusDot extends StatelessWidget {
  final RequestMediaStatus status;

  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String tooltip;
    switch (status) {
      case RequestMediaStatus.available:
        color = AppColors.success;
        tooltip = 'Disponible';
      case RequestMediaStatus.partial:
        color = AppColors.warning;
        tooltip = 'Partiellement disponible';
      case RequestMediaStatus.pending:
      case RequestMediaStatus.processing:
        color = AppColors.accentMuted;
        tooltip = 'En attente';
      case RequestMediaStatus.unknown:
        return const SizedBox.shrink();
    }

    return Tooltip(
      message: tooltip,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.6),
              blurRadius: 8,
              spreadRadius: 0.5,
            ),
          ],
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
      ),
    );
  }
}
