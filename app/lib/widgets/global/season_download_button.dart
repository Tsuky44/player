import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../models/offline_download.dart';
import '../../services/download_manager.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import 'metered_download_dialog.dart';

/// « Garder toute la saison sur l'appareil », en un geste.
///
/// Vingt appuis sur vingt lignes faisaient exactement la même chose, et
/// c'est précisément le geste qu'on fait avant de partir — donc au moment où
/// l'on a le moins envie de compter les épisodes. Le bouton ne rapatrie que ce
/// qui manque : relancé au milieu d'une saison, il complète.
class SeasonDownloadButton extends StatelessWidget {
  final List<HomeMediaItem> episodes;
  final String showTitle;
  final int showId;
  final String? showPosterUrl;
  final int? seasonNumber;

  const SeasonDownloadButton({
    super.key,
    required this.episodes,
    required this.showTitle,
    required this.showId,
    this.showPosterUrl,
    this.seasonNumber,
  });

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    if (!manager.isSupported) return const SizedBox.shrink();

    // Sur un téléphone, le libellé partage sa ligne avec « Épisodes » et le
    // compte de disponibles : il se dit en un mot ou il déborde.
    final compact = AppLayout.isCompact(context);

    final downloadable = [
      for (final episode in episodes)
        if (episode.isAvailable && episode.media.type == MediaType.episode)
          episode,
    ];
    if (downloadable.isEmpty) return const SizedBox.shrink();

    final entries = <OfflineDownload?>[
      for (final episode in downloadable) manager.entryFor(episode.media.id),
    ];
    final done = entries.where((e) => e?.isCompleted ?? false).length;
    final running = entries.where((e) => e?.isActive ?? false).length;
    final missing = downloadable.length - done - running;

    // Tout est là : le bouton devient la sortie — c'est le seul endroit d'où
    // une saison entière se libère d'un coup.
    if (missing == 0 && running == 0) {
      return TextButton.icon(
        onPressed: () => _deleteSeason(context, manager, downloadable),
        icon: const Icon(Icons.download_done_rounded, size: 18),
        label: Text(
          compact ? 'Téléchargée' : 'Saison téléchargée · ${_labelFor(done)}',
        ),
        style: TextButton.styleFrom(foregroundColor: AppColors.success),
      );
    }

    if (running > 0) {
      return TextButton.icon(
        onPressed: missing == 0
            ? null
            : () => _downloadSeason(context, manager, downloadable),
        icon: const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('$done/${downloadable.length}'),
        style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
      );
    }

    return TextButton.icon(
      onPressed: () => _downloadSeason(context, manager, downloadable),
      icon: const Icon(Icons.download_outlined, size: 18),
      label: Text(
        done > 0
            ? (compact ? 'Compléter ($missing)' : 'Compléter · ${_labelFor(missing)}')
            : (compact ? 'La saison' : 'Télécharger la saison'),
      ),
      style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
    );
  }

  static String _labelFor(int count) =>
      '$count épisode${count > 1 ? 's' : ''}';

  Future<void> _downloadSeason(
    BuildContext context,
    DownloadManager manager,
    List<HomeMediaItem> downloadable,
  ) async {
    final pending = [
      for (final episode in downloadable)
        if (!(manager.entryFor(episode.media.id)?.isCompleted ?? false)) episode,
    ];
    if (pending.isEmpty) return;

    final proceed = await confirmDownloadOnThisNetwork(
      context,
      what: 'les ${_labelFor(pending.length)} de cette saison',
    );
    if (!proceed) return;

    await manager.downloadAll(
      pending,
      showTitle: showTitle,
      showId: showId,
      seasonNumber: seasonNumber,
      showPosterUrl: showPosterUrl,
    );
  }

  Future<void> _deleteSeason(
    BuildContext context,
    DownloadManager manager,
    List<HomeMediaItem> downloadable,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Supprimer la saison ?'),
        content: Text(
          '${_labelFor(downloadable.length)} seront effacés de cet appareil. '
          'Ils restent disponibles sur le serveur.',
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
    if (confirmed != true) return;

    for (final episode in downloadable) {
      await manager.delete(episode.media.id);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('${_labelFor(downloadable.length)} supprimés')),
    );
  }
}
