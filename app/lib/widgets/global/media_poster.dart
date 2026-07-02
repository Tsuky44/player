import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';

class MediaPoster extends StatelessWidget {
  final Media media;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;
  final Alignment alignment;
  final String? posterUrlOverride;

  const MediaPoster({
    super.key,
    required this.media,
    required this.width,
    required this.height,
    this.borderRadius = 6,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.posterUrlOverride,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final resolvedUrl = resolvePosterUrl(
      posterUrlOverride ?? media.posterUrl,
      serverBaseUrl: apiClient.baseUrl,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: resolvedUrl != null
            ? CachedNetworkImage(
                imageUrl: resolvedUrl,
                fit: fit,
                alignment: alignment,
                fadeInDuration: const Duration(milliseconds: 200),
                memCacheWidth: (width * 2).round(),
                memCacheHeight: (height * 2).round(),
                placeholder: (_, __) => _fallback(showLoader: true),
                errorWidget: (_, __, ___) => _fallback(),
              )
            : _fallback(),
      ),
    );
  }

  Widget _fallback({bool showLoader = false}) {
    final isShow = media.type == MediaType.show ||
        media.type == MediaType.season ||
        media.type == MediaType.episode;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfaceElevated,
            AppColors.surfaceElevated.withValues(alpha: 0.7),
          ],
        ),
      ),
      child: showLoader
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isShow ? Icons.tv_rounded : Icons.movie_rounded,
                  size: (width * 0.22).clamp(24.0, 48.0),
                  color: AppColors.textMuted,
                ),
              ],
            ),
    );
  }
}
