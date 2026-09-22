import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../navigation/detail_prefetch.dart';
import '../../services/api_client.dart';
import '../../utils/format.dart';
import '../../utils/poster_url.dart';
import 'poster_card.dart';
import 'progress_pill.dart';
import 'watch_badge.dart';

class MediaCard extends StatelessWidget {
  final Media media;
  final double? progress;

  /// Film déjà vu — la pastille verte. Ignoré pour les séries, qui déduisent la
  /// leur du décompte d'épisodes porté par [media].
  final bool watched;
  final VoidCallback onTap;
  final bool compact;

  /// See [PosterCard.autofocus].
  final bool autofocus;

  const MediaCard({
    super.key,
    required this.media,
    this.progress,
    this.watched = false,
    required this.onTap,
    this.compact = false,
    this.autofocus = false,
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
    final badge = WatchBadge.forMedia(media, watched: watched);

    return PosterCard(
      posterUrl: url,
      title: media.title,
      subtitle: year,
      onTap: onTap,
      onPrefetch: () => DetailPrefetch.warm(context, media),
      compact: compact,
      autofocus: autofocus,
      showPlayOnHover: true,
      placeholderIcon: isShow ? Icons.tv_rounded : Icons.movie_rounded,
      overlays: [
        if (badge != null)
          Positioned(
            top: PosterCard.overlayInset,
            right: PosterCard.overlayInset,
            child: badge,
          ),
      ],
      footerOverlay: inProgress ? ProgressPill(value: progress!) : null,
    );
  }
}
