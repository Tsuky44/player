import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import 'hero_banner.dart' show MetadataChip;

/// Describes the original file, independently of the playback device.
class MediaTechnicalSection extends StatelessWidget {
  final MediaTracks? tracks;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;

  const MediaTechnicalSection({
    super.key,
    required this.tracks,
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final video = tracks?.video;
    final audio = tracks?.audio ?? const <MediaAudioTrack>[];
    final videoLabels = <String>[
      if (video != null) ...[
        if (video.resolutionLabel.isNotEmpty) video.resolutionLabel,
        if (video.codec.isNotEmpty) video.codecLabel,
        if (video.hdrLabel.isNotEmpty) video.hdrLabel,
        if (video.bitDepth > 8) '${video.bitDepth} bits',
      ],
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppLayout.pagePadding(context),
        24,
        AppLayout.pagePadding(context),
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Média sur le serveur',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  )),
          const SizedBox(height: 12),
          if (loading)
            const Text('Chargement des formats…',
                style: TextStyle(color: AppColors.textSecondary))
          else if (failed) ...[
            const Text('Impossible de charger les formats du fichier.',
                style: TextStyle(color: AppColors.textSecondary)),
            TextButton(onPressed: onRetry, child: const Text('Réessayer')),
          ] else ...[
            if (videoLabels.isNotEmpty) ...[
              const Text('Vidéo',
                  style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final label in videoLabels) MetadataChip(label: label),
                ],
              ),
              if (video!.width > 0 && video.height > 0) ...[
                const SizedBox(height: 8),
                Text('${video.width} × ${video.height}',
                    style: const TextStyle(color: AppColors.textSecondary)),
              ],
            ],
            if (audio.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Audio',
                  style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              for (final track in audio)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(track.displayName,
                      style: const TextStyle(
                          color: AppColors.textPrimary, height: 1.5)),
                ),
            ],
            if (videoLabels.isEmpty && audio.isEmpty)
              const Text('Formats indisponibles pour ce fichier.',
                  style: TextStyle(color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}
