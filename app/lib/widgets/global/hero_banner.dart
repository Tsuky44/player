import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';

class HeroBanner extends StatelessWidget {
  final Media media;
  final String? subtitle;
  final String? titleOverride;
  final String? backgroundUrlOverride;
  final String playLabel;
  final VoidCallback onPlay;
  final VoidCallback? onInfo;

  const HeroBanner({
    super.key,
    required this.media,
    this.subtitle,
    this.titleOverride,
    this.backgroundUrlOverride,
    this.playLabel = 'LECTURE',
    required this.onPlay,
    this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final posterUrl = backgroundUrlOverride ??
        resolveHeroImageUrl(media.posterUrl, serverBaseUrl: apiClient.baseUrl);
    final title = titleOverride ?? media.title;
    final year = extractYear(media.releaseDate);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (screenWidth * dpr).round().clamp(960, 2560);
    final isCompact = screenWidth < 600;
    final horizontalPadding = isCompact ? 16.0 : 48.0;
    final bannerHeight = (screenHeight * (isCompact ? 0.55 : 0.65)).clamp(360.0, 580.0);

    return SizedBox(
      height: bannerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posterUrl != null)
            CachedNetworkImage(
              imageUrl: posterUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.high,
              memCacheWidth: cacheWidth,
            )
          else
            Container(color: AppColors.surfaceElevated),

          // Gradients
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.2),
                  Colors.black.withValues(alpha: 0.5),
                  AppColors.background,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black.withValues(alpha: 0.3),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.35, 0.7],
              ),
            ),
          ),

          // Content
          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            bottom: isCompact ? 48 : 80,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isCompact ? double.infinity : 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mediaTypeLabel(media.type),
                    style: const TextStyle(
                      color: AppColors.accentMuted,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: isCompact ? 28 : 42,
                          height: 1.05,
                          letterSpacing: -0.8,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.8),
                              blurRadius: 16,
                            ),
                          ],
                        ),
                  ),
                  if (year != null || subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      [if (year != null) year, if (subtitle != null) subtitle]
                          .join(' · '),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (media.overview != null && media.overview!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      media.overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _PlayButton(label: playLabel, onPressed: onPlay),
                      if (onInfo != null)
                        _InfoButton(
                          onPressed: onInfo!,
                          compact: isCompact,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _PlayButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.play_arrow_rounded, size: 28),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;

  const _InfoButton({required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.info_outline_rounded, size: 22),
      label: Text(compact ? 'INFOS' : 'PLUS D\'INFOS'),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.15),
        side: BorderSide.none,
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 24,
          vertical: 14,
        ),
      ),
    );
  }
}

class DetailHero extends StatelessWidget {
  final Media media;
  final Widget? actions;
  final List<Widget>? metadata;

  const DetailHero({
    super.key,
    required this.media,
    this.actions,
    this.metadata,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final posterUrl = resolvePosterUrl(media.posterUrl, serverBaseUrl: apiClient.baseUrl);
    const heroHeight = 480.0;

    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posterUrl != null)
            CachedNetworkImage(
              imageUrl: posterUrl,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            )
          else
            Container(color: AppColors.surfaceElevated),

          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.3),
                  AppColors.background,
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.background.withValues(alpha: 0.95),
                  AppColors.background.withValues(alpha: 0.4),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45, 0.8],
              ),
            ),
          ),

          Positioned(
            left: 48,
            right: 48,
            bottom: 32,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (posterUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: posterUrl,
                      width: 180,
                      height: 270,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  Container(
                    width: 180,
                    height: 270,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.movie_rounded, size: 48, color: AppColors.textMuted),
                  ),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mediaTypeLabel(media.type),
                        style: const TextStyle(
                          color: AppColors.accentMuted,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        media.title,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              letterSpacing: -0.4,
                            ),
                      ),
                      if (metadata != null && metadata!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: metadata!,
                        ),
                      ],
                      if (media.overview != null && media.overview!.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          media.overview!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            height: 1.55,
                          ),
                        ),
                      ],
                      if (actions != null) ...[
                        const SizedBox(height: 20),
                        actions!,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MetadataChip extends StatelessWidget {
  final String label;

  const MetadataChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
