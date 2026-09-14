import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/api_client.dart';
import '../../../theme/app_colors.dart';
import '../../../utils/poster_url.dart';
import '../../../widgets/global/app_network_image.dart';

/// Une petite affiche au format 2:3, avec une icône quand il n'y en a pas.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.posterUrl,
    this.width = 44,
    this.isShow = false,
  });

  final String posterUrl;
  final double width;
  final bool isShow;

  @override
  Widget build(BuildContext context) {
    final url = posterUrl.isEmpty
        ? null
        : cardPosterUrl(posterUrl,
            serverBaseUrl: context.read<ApiClient>().baseUrl);
    final fallback = Container(
      color: AppColors.surfaceElevated,
      alignment: Alignment.center,
      child: Icon(
        isShow ? Icons.tv_rounded : Icons.movie_outlined,
        size: width * 0.4,
        color: AppColors.textMuted,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(width * 0.14),
      child: SizedBox(
        width: width,
        height: width * 1.5,
        child: url == null
            ? fallback
            : AppNetworkImage(
                url: url,
                width: width,
                height: width * 1.5,
                fit: BoxFit.cover,
                errorWidget: fallback,
              ),
      ),
    );
  }
}
