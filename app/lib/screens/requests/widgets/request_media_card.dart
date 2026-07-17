import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../models/media_request.dart';
import '../../../theme/app_colors.dart';

class RequestMediaCard extends StatelessWidget {
  final RequestMediaItem item;
  final VoidCallback onTap;

  const RequestMediaCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: item.posterUrl == null
                      ? const ColoredBox(
                          color: AppColors.surfaceElevated,
                          child: Icon(Icons.movie_outlined,
                              color: AppColors.textMuted, size: 42),
                        )
                      : CachedNetworkImage(
                          imageUrl: item.posterUrl!,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const ColoredBox(
                              color: AppColors.surfaceElevated),
                          errorWidget: (_, __, ___) => const ColoredBox(
                            color: AppColors.surfaceElevated,
                            child: Icon(Icons.broken_image_outlined,
                                color: AppColors.textMuted),
                          ),
                        ),
                ),
                Positioned(
                    top: 8, left: 8, child: _TypeBadge(type: item.mediaType)),
                if (item.status != RequestMediaStatus.unknown)
                  Positioned(
                      top: 8,
                      right: 8,
                      child: _StatusBadge(status: item.status)),
              ],
            ),
          ),
          const SizedBox(height: 9),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w600, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 3),
          Text(
            [
              if (item.year != null) item.year!,
              if (item.rating > 0) '★ ${item.rating.toStringAsFixed(1)}'
            ].join('  •  '),
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final RequestMediaType type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    return _Badge(
        label: type == RequestMediaType.movie ? 'FILM' : 'SÉRIE',
        color: AppColors.accent);
  }
}

class _StatusBadge extends StatelessWidget {
  final RequestMediaStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final available = status == RequestMediaStatus.available ||
        status == RequestMediaStatus.partial;
    return _Badge(
      label: available ? 'DISPONIBLE' : 'DEMANDÉ',
      color: available ? AppColors.success : AppColors.primary,
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: const TextStyle(
              fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
    );
  }
}
