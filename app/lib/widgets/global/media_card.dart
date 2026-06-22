import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/models.dart';

class MediaCard extends StatelessWidget {
  final Media media;
  final double width;
  final double height;
  final double? progress; // Watch progression (from 0.0 to 1.0)
  final VoidCallback onTap;

  const MediaCard({
    super.key,
    required this.media,
    this.width = 130,
    this.height = 195,
    this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPoster = media.posterUrl != null && media.posterUrl!.isNotEmpty;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Poster Container with Progress overlay
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                // 1. Poster Image
                SizedBox(
                  width: width,
                  height: height,
                  child: hasPoster
                      ? CachedNetworkImage(
                          imageUrl: media.posterUrl!,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: const Color(0xFF2B2B2B),
                            child: const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF00A4DC),
                              ),
                            ),
                          ),
                          errorWidget: (context, url, error) => _buildFallbackPoster(),
                        )
                      : _buildFallbackPoster(),
                ),

                // 2. Play Icon Overlay on Hover (Visual decoration)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.15),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),

                // 3. Progress Bar Overlay at bottom
                if (progress != null && progress! > 0 && progress! < 0.99)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 4,
                      color: Colors.black.withOpacity(0.5),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress,
                          child: Container(
                            color: const Color(0xFFE50914), // Netflix Red for watch progression
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Title
          SizedBox(
            width: width,
            child: Text(
              media.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
          // Subtitle / Year
          if (media.releaseDate != null && media.releaseDate!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              media.releaseDate!.split('-').first, // Extract year
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Placeholder poster if poster URL fails or is empty
  Widget _buildFallbackPoster() {
    final isShow = media.type == MediaType.show;
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF222222),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isShow ? Icons.tv_off : Icons.movie_creation_outlined,
            size: 36,
            color: Colors.grey,
          ),
          const SizedBox(height: 12),
          Text(
            media.title,
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
