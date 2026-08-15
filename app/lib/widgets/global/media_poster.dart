import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import 'app_network_image.dart';

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
    this.borderRadius = 12,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.posterUrlOverride,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    // Same normalisation as MediaCard. Without it the catalog's w300 poster and
    // the card's w500 one were two URLs for one image, fetched separately.
    final resolvedUrl = cardPosterUrl(
      posterUrlOverride ?? media.posterUrl,
      serverBaseUrl: apiClient.baseUrl,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: AppNetworkImage(
          // No per-media cache key: two rows showing the same title, or a show
          // and one of its episodes sharing artwork, used to be filed as
          // separate entries and downloaded once each.
          url: resolvedUrl,
          width: width,
          height: height,
          fit: fit,
          alignment: alignment,
          fadeInDuration: const Duration(milliseconds: 200),
          // A flat fill, not a spinner: these are laid out in rows of a dozen,
          // and a dozen spinners read as a page that is broken rather than one
          // that is loading.
          placeholder: _fallback(withIcon: false),
          errorWidget: _fallback(),
        ),
      ),
    );
  }

  /// The empty slot. [withIcon] is off while the bytes are in flight — an icon
  /// that appears for a few hundred ms and is then replaced reads as a load
  /// failure; the bare surface reads as the poster arriving.
  Widget _fallback({bool withIcon = true}) {
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
      child: withIcon
          ? Center(
              child: Icon(
                isShow ? Icons.tv_rounded : Icons.movie_rounded,
                size: (width * 0.22).clamp(24.0, 48.0),
                color: AppColors.textMuted,
              ),
            )
          : null,
    );
  }
}
