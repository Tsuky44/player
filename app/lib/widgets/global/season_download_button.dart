import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/download_manager.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import 'bulk_download_delete.dart';
import 'metered_download_dialog.dart';
import 'season_download_plan.dart';
import '../../theme/app_icons.dart';
import '../../l10n/tr.dart';

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

    final plan = SeasonDownloadPlan.of(episodes, manager.entryFor);
    if (plan.isEmpty) return const SizedBox.shrink();
    final nextBatch = plan.nextBatch;
    final VoidCallback? addNext = nextBatch == null
        ? null
        : () => _downloadSeason(context, manager, nextBatch,
            unwatchedOnly: plan.nextBatchIsUnwatched);

    // Tout est là : le bouton devient la sortie — c'est le seul endroit d'où
    // une saison entière se libère d'un coup.
    if (plan.isComplete) {
      return TextButton.icon(
        onPressed: () => _deleteSeason(context, manager, plan.downloadable),
        icon: const Icon(AppIcons.downloaded, size: 18),
        label: Text(
          compact
              ? tr('Téléchargée')
              : tr('Saison téléchargée · {0}', [_labelFor(plan.done)]),
        ),
        style: TextButton.styleFrom(foregroundColor: AppColors.success),
      );
    }

    if (plan.running > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: addNext,
            icon: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: Text('${plan.done}/${plan.requested}'),
            style:
                TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          ),
          // Une saison lancée par erreur, ou sur le mauvais réseau, se
          // défaisait épisode par épisode depuis l'écran des téléchargements.
          // L'arrêt porte sur toute la série : la réserve automatique a pu
          // mettre en file la saison suivante, et elle fait partie du même
          // geste.
          IconButton(
            onPressed: () => _cancelShow(context, manager),
            tooltip: tr('Annuler les téléchargements de la série'),
            icon: const Icon(AppIcons.close, size: 18),
            visualDensity: VisualDensity.compact,
            color: AppColors.textSecondary,
          ),
        ],
      );
    }

    final String label;
    if (plan.nextBatchIsUnwatched) {
      label = compact
          ? tr('Non vus ({0})', [plan.unwatchedMissing])
          : tr('Télécharger les non vus · {0}', [_labelFor(plan.unwatchedMissing)]);
    } else if (plan.done > 0) {
      label = compact
          ? tr('Compléter ({0})', [plan.missing])
          : tr('Compléter · {0}', [_labelFor(plan.missing)]);
    } else {
      label = compact ? tr('La saison') : tr('Télécharger la saison');
    }
    return TextButton.icon(
      onPressed: addNext,
      icon: const Icon(AppIcons.download, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
    );
  }

  static String _labelFor(int count) =>
      tr('{0} épisode{1}', [count, count > 1 ? 's' : '']);

  Future<void> _downloadSeason(
    BuildContext context,
    DownloadManager manager,
    List<HomeMediaItem> candidates, {
    bool unwatchedOnly = false,
  }) async {
    final pending = [
      for (final episode in candidates)
        if (!(manager.entryFor(episode.media.id)?.isCompleted ?? false)) episode,
    ];
    if (pending.isEmpty) return;

    final proceed = await confirmDownloadOnThisNetwork(
      context,
      what: unwatchedOnly
          ? tr('les {0} non vus de cette saison', [_labelFor(pending.length)])
          : tr('les {0} de cette saison', [_labelFor(pending.length)]),
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

  Future<void> _cancelShow(
    BuildContext context,
    DownloadManager manager,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(tr('Annuler les téléchargements ?')),
        content: Text(
          tr('Les épisodes de {0} pas encore sur l’appareil sont retirés de '
              'la file. Ceux déjà téléchargés restent.', [showTitle]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Continuer')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(tr('Tout annuler')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final cancelled = await manager.cancelShow(showId);
    if (cancelled == 0) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tr('{0} téléchargement{1} annulé{2}', [cancelled, cancelled > 1 ? 's' : '', cancelled > 1 ? 's' : '']),
        ),
      ),
    );
  }

  Future<void> _deleteSeason(
    BuildContext context,
    DownloadManager manager,
    List<HomeMediaItem> downloadable,
  ) =>
      confirmDeleteDownloads(
        context,
        what: seasonNumber == null ? tr('la saison') : tr('la saison {0}', [seasonNumber]),
        entries: [
          for (final episode in downloadable)
            if (manager.entryFor(episode.media.id) case final entry?) entry,
        ],
      );
}
