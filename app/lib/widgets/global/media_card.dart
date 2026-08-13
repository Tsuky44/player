import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import 'poster_card.dart';

class MediaCard extends StatelessWidget {
  final Media media;
  final double? progress;
  final VoidCallback onTap;
  final bool compact;

  const MediaCard({
    super.key,
    required this.media,
    this.progress,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final apiClient = Provider.of<ApiClient>(context, listen: false);
    final url = cardPosterUrl(media.posterUrl, serverBaseUrl: apiClient.baseUrl);
    final year = extractYear(media.releaseDate);
    final isShow = media.type == MediaType.show ||
        media.type == MediaType.season ||
        media.type == MediaType.episode;
    final inProgress = progress != null && progress! > 0 && progress! < 0.99;

    return PosterCard(
      posterUrl: url,
      cacheKey: url == null ? null : '${media.id}_$url',
      title: media.title,
      subtitle: year,
      onTap: onTap,
      compact: compact,
      showPlayOnHover: true,
      placeholderIcon: isShow ? Icons.tv_rounded : Icons.movie_rounded,
      footerOverlay: inProgress
          ? LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.black.withValues(alpha: 0.45),
              valueColor: const AlwaysStoppedAnimation(AppColors.progress),
            )
          : null,
    );
  }
}
