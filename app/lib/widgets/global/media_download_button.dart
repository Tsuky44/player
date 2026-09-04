import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../models/offline_download.dart';
import '../../services/download_manager.dart';
import '../../theme/app_colors.dart';

/// Le bouton « garder sur l'appareil », partout où un média se télécharge.
///
/// Un seul contrôle porte tout le cycle de vie — lancer, mettre en pause,
/// reprendre, supprimer — parce que c'est un seul état que l'utilisateur suit :
/// « est-ce que cet épisode est chez moi ? ». Un bouton par transition aurait
/// demandé de la place que la tuile d'épisode n'a pas, et aurait fait clignoter
/// la ligne à chaque changement.
class MediaDownloadButton extends StatelessWidget {
  final HomeMediaItem item;

  /// Contexte que l'épisode ne porte pas lui-même et que l'écran hors ligne ne
  /// pourra plus aller chercher : sans nom de série, un téléchargement se
  /// retrouve seul dans la liste sous son seul titre d'épisode.
  final String? showTitle;
  final int? showId;
  final int? seasonNumber;
  final String? showPosterUrl;

  /// Version réduite pour une ligne de liste.
  final bool compact;

  const MediaDownloadButton({
    super.key,
    required this.item,
    this.showTitle,
    this.showId,
    this.seasonNumber,
    this.showPosterUrl,
    this.compact = false,
  });

  bool get _isDownloadable =>
      item.isAvailable &&
      (item.media.type == MediaType.movie ||
          item.media.type == MediaType.episode);

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    if (!manager.isSupported || !_isDownloadable) {
      return const SizedBox.shrink();
    }

    final entry = manager.entryFor(item.media.id);
    final size = compact ? 20.0 : 22.0;

    return IconButton(
      tooltip: _tooltip(entry),
      onPressed: () => _onPressed(context, manager, entry),
      iconSize: size,
      visualDensity: compact ? VisualDensity.compact : null,
      icon: _icon(entry, size),
    );
  }

  Widget _icon(OfflineDownload? entry, double size) {
    switch (entry?.status) {
      case null:
        return const Icon(Icons.download_outlined,
            color: AppColors.textSecondary);
      case DownloadStatus.completed:
        return const Icon(Icons.download_done_rounded,
            color: AppColors.success);
      case DownloadStatus.failed:
        return const Icon(Icons.error_outline_rounded,
            color: AppColors.textSecondary);
      case DownloadStatus.paused:
        return const Icon(Icons.pause_circle_outline_rounded,
            color: AppColors.textSecondary);
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        // L'anneau porte l'avancement et l'icône porte l'action : un carré
        // d'arrêt au centre, pour qu'un appui pendant le transfert ne soit
        // jamais ambigu.
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: entry!.progress,
                strokeWidth: 2,
                backgroundColor: AppColors.border,
                valueColor:
                    const AlwaysStoppedAnimation(AppColors.textPrimary),
              ),
              Icon(Icons.stop_rounded,
                  size: size * 0.5, color: AppColors.textSecondary),
            ],
          ),
        );
    }
  }

  String _tooltip(OfflineDownload? entry) {
    switch (entry?.status) {
      case null:
        return 'Télécharger';
      case DownloadStatus.completed:
        return 'Téléchargé';
      case DownloadStatus.failed:
        return entry!.error ?? 'Échec du téléchargement';
      case DownloadStatus.paused:
        return 'Reprendre le téléchargement';
      case DownloadStatus.queued:
        return 'En attente';
      case DownloadStatus.downloading:
        return 'Téléchargement en cours';
    }
  }

  Future<void> _onPressed(
    BuildContext context,
    DownloadManager manager,
    OfflineDownload? entry,
  ) async {
    switch (entry?.status) {
      case null:
      case DownloadStatus.failed:
        await manager.download(
          item,
          showTitle: showTitle,
          showId: showId,
          seasonNumber: seasonNumber,
          showPosterUrl: showPosterUrl,
        );
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        await manager.pause(item.media.id);
      case DownloadStatus.paused:
        await manager.resume(item.media.id);
      case DownloadStatus.completed:
        // Effacer un fichier de plusieurs gigaoctets sur un appui qui visait
        // peut-être la ligne d'à côté : la confirmation n'est pas négociable.
        final confirmed = await confirmDeleteDownload(context, entry!);
        if (confirmed) await manager.delete(item.media.id);
    }
  }
}

/// Demande confirmation avant d'effacer un média du disque.
///
/// Partagée par le bouton et l'écran des téléchargements pour que la question
/// soit posée dans les mêmes termes des deux côtés.
Future<bool> confirmDeleteDownload(
  BuildContext context,
  OfflineDownload entry,
) async {
  final unsynced = entry.needsSync;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Supprimer le téléchargement ?'),
      content: Text(
        unsynced
            ? '« ${entry.title} » libérera de la place sur cet appareil. '
                'Son avancement sera envoyé au serveur dès que possible.'
            : '« ${entry.title} » libérera de la place sur cet appareil. '
                'Le média reste disponible sur le serveur.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  return result ?? false;
}
