import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../desktop_window.dart';
import '../../models/models.dart';
import '../../models/offline_download.dart';
import '../../navigation/search_route_observer.dart';
import '../../services/download_manager.dart';
import '../../services/server_reachability.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_focus.dart';
import '../../utils/format.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/local_file_image.dart';
import '../../widgets/global/media_download_button.dart';
import '../player/player_screen.dart';

/// Ce qui est sur l'appareil, et rien d'autre.
///
/// C'est le seul écran qui tient debout sans serveur, et c'est sa raison
/// d'être : dans un avion ou dans un métro, c'est l'app tout entière. Il ne
/// fait donc aucun appel réseau — tout ce qu'il affiche vient du manifeste
/// local, y compris les affiches.
class DownloadsScreen extends StatelessWidget {
  final bool embedded;

  const DownloadsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final reachability = context.watch<ServerReachability>();
    final compact = AppLayout.isCompact(context);
    final pad = AppLayout.pagePadding(context);
    final items = manager.downloads;
    final groups = _groupByShow(items);
    final watchedCount =
        items.where((e) => e.isCompleted && e.isFinished).length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                pad,
                embedded
                    ? embeddedShellContentTopInset(context)
                    : (compact ? MediaQuery.paddingOf(context).top + 56 : 48),
                pad,
                0,
              ),
              child: _Header(
                compact: compact,
                itemCount: items.length,
                bytes: manager.totalBytesOnDisk,
                watchedCount: watchedCount,
                offline: reachability.isOffline,
                pendingSync: manager.pendingSyncCount,
              ),
            ),
          ),
          if (!manager.isSupported)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyStateView(
                icon: Icons.cloud_off_rounded,
                title: 'Indisponible ici',
                message:
                    'Le téléchargement hors ligne demande un espace de stockage '
                    "propre à l'application. Utilisez l'app installée sur votre "
                    'appareil.',
              ),
            )
          else if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyStateView(
                icon: Icons.download_for_offline_outlined,
                title: 'Aucun téléchargement',
                message:
                    "Depuis la fiche d'un film ou d'une série, le bouton de "
                    'téléchargement garde le média sur cet appareil. Il reste '
                    'lisible même sans serveur.',
              ),
            )
          else
            for (final group in groups) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(pad, 24, pad, 8),
                  child: _GroupHeader(
                    title: group.title,
                    infoId: group.infoId,
                    episodeCount: group.entries.length,
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: group.entries.length,
                itemBuilder: (context, index) => _DownloadRow(
                  entry: group.entries[index],
                  compact: compact,
                ),
              ),
            ],
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }

  /// Regroupe par série, les films ensemble à la fin.
  ///
  /// L'ordre à l'intérieur d'une série est celui des numéros, pas celui du
  /// téléchargement : on regarde une saison dans l'ordre, quel que soit celui
  /// dans lequel on l'a rapatriée.
  static List<_Group> _groupByShow(List<OfflineDownload> items) {
    final byShow = <String, List<OfflineDownload>>{};
    final movies = <OfflineDownload>[];
    for (final item in items) {
      if (item.showTitle != null && item.showTitle!.isNotEmpty) {
        byShow.putIfAbsent(item.showTitle!, () => []).add(item);
      } else {
        movies.add(item);
      }
    }
    final groups = <_Group>[];
    final showTitles = byShow.keys.toList()..sort();
    for (final title in showTitles) {
      final entries = byShow[title]!
        ..sort((a, b) {
          final season =
              (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
          if (season != 0) return season;
          return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
        });
      groups.add(_Group(title, entries, infoId: entries.first.infoId));
    }
    if (movies.isNotEmpty) {
      movies.sort((a, b) => a.title.compareTo(b.title));
      // Pas de fiche commune : chaque film est la sienne, et l'en-tête « Films »
      // ne décrit rien d'autre qu'un regroupement.
      groups.add(_Group('Films', movies));
    }
    return groups;
  }
}

class _Group {
  final String title;
  final List<OfflineDownload> entries;

  /// Identifiant sous lequel la fiche de la série est rangée, quand il y en a
  /// une (null pour le regroupement des films).
  final int? infoId;

  const _Group(this.title, this.entries, {this.infoId});
}

/// L'en-tête d'une série, nourri par la fiche rapatriée avec ses épisodes.
///
/// Sans elle il n'y aurait qu'un titre : c'est la fiche qui apporte l'affiche,
/// l'année, les genres et le synopsis — soit tout ce qui permet de reconnaître
/// une série sans serveur pour la décrire.
class _GroupHeader extends StatefulWidget {
  final String title;
  final int? infoId;
  final int episodeCount;

  const _GroupHeader({
    required this.title,
    required this.infoId,
    required this.episodeCount,
  });

  @override
  State<_GroupHeader> createState() => _GroupHeaderState();
}

class _GroupHeaderState extends State<_GroupHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final infoId = widget.infoId;
    final details = infoId == null ? null : manager.detailsForShow(infoId);
    final posterPath = infoId == null ? null : manager.showPosterPath(infoId);

    final titleWidget = Text(
      widget.title,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    );

    // Rien à décorer : on garde exactement l'en-tête d'avant.
    if (details == null && posterPath == null) return titleWidget;

    final overview = details?.overview?.trim() ?? '';
    final meta = _metaLine(details);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (posterPath != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 46,
              height: 69,
              child: localFileImage(posterPath),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleWidget,
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  meta,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
              if (overview.isNotEmpty) ...[
                const SizedBox(height: 6),
                // Le synopsis complet en tête de chaque série repousserait les
                // épisodes hors de l'écran : deux lignes, le reste sur demande.
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    overview,
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _metaLine(MediaDetails? details) {
    final parts = <String>[
      '${widget.episodeCount} ${widget.episodeCount > 1 ? 'éléments' : 'élément'}',
    ];
    if (details != null) {
      final year = extractYear(details.releaseDate);
      if (year != null) parts.add(year);
      if (details.numberOfSeasons > 0) {
        parts.add(
          '${details.numberOfSeasons} saison${details.numberOfSeasons > 1 ? 's' : ''}',
        );
      }
      if (details.genres.isNotEmpty) parts.add(details.genres.take(2).join(', '));
      if (details.voteAverage > 0) {
        parts.add('★ ${details.voteAverage.toStringAsFixed(1)}');
      }
    }
    return parts.join(' · ');
  }
}

class _Header extends StatelessWidget {
  final bool compact;
  final int itemCount;
  final int bytes;
  final int watchedCount;
  final bool offline;
  final int pendingSync;

  const _Header({
    required this.compact,
    required this.itemCount,
    required this.bytes,
    required this.watchedCount,
    required this.offline,
    required this.pendingSync,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Téléchargements',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: compact ? 26 : 32,
                      color: AppColors.textPrimary,
                    ),
              ),
            ),
            if (watchedCount > 0)
              TextButton.icon(
                onPressed: () => _deleteWatched(context, watchedCount),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: Text(compact
                    ? 'Vus ($watchedCount)'
                    : 'Supprimer les vus ($watchedCount)'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        if (itemCount > 0) ...[
          const SizedBox(height: 4),
          Text(
            '$itemCount ${itemCount > 1 ? 'éléments' : 'élément'} · ${formatBytes(bytes)}',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
            ),
          ),
        ],
        if (offline) ...[
          const SizedBox(height: 16),
          _Banner(
            icon: Icons.cloud_off_rounded,
            color: AppColors.warning,
            text: pendingSync > 0
                ? 'Serveur injoignable. $pendingSync ${pendingSync > 1 ? 'lectures seront synchronisées' : 'lecture sera synchronisée'} au retour de la connexion.'
                : 'Serveur injoignable. Vous pouvez regarder ce qui est sur cet appareil.',
          ),
        ] else if (pendingSync > 0) ...[
          const SizedBox(height: 16),
          _Banner(
            icon: Icons.sync_rounded,
            color: AppColors.accent,
            text:
                'Synchronisation de $pendingSync ${pendingSync > 1 ? 'lectures' : 'lecture'} avec le serveur…',
          ),
        ],
      ],
    );
  }

  Future<void> _deleteWatched(BuildContext context, int count) async {
    final manager = context.read<DownloadManager>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Supprimer les médias vus ?'),
        content: Text(
          '$count ${count > 1 ? 'éléments seront effacés' : 'élément sera effacé'} '
          'de cet appareil. Ils restent disponibles sur le serveur.',
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
    final deleted = await manager.deleteWatched();
    messenger.showSnackBar(SnackBar(
      content: Text('$deleted ${deleted > 1 ? 'éléments supprimés' : 'élément supprimé'}'),
    ));
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final OfflineDownload entry;
  final bool compact;

  const _DownloadRow({required this.entry, required this.compact});

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManager>();
    final pad = AppLayout.pagePadding(context);
    final thumbW = compact ? 104.0 : 140.0;
    final thumbH = thumbW * 9 / 16;
    final playable = entry.isCompleted;

    return TvFocusable(
      enabled: playable,
      onSelect: () => _play(context),
      focusScale: 1.0,
      scrollAlignment: 0.3,
      showRing: false,
      child: InkWell(
        onTap: playable ? () => _play(context) : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(
                entry: entry,
                width: thumbW,
                height: thumbH,
                manager: manager,
              ),
              SizedBox(width: compact ? 12 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (entry.episodeCode != null) entry.episodeCode!,
                        entry.title,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: compact ? 14 : 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _statusLine(entry),
                      style: TextStyle(
                        color: entry.status == DownloadStatus.failed
                            ? AppColors.error
                            : AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    if (entry.isActive) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: entry.progress,
                          minHeight: 3,
                          backgroundColor: AppColors.border,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.progress),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _RowActions(entry: entry),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(OfflineDownload entry) {
    switch (entry.status) {
      case DownloadStatus.completed:
        final size = formatBytes(entry.bytesTotal);
        if (entry.isFinished) return 'Vu · $size';
        if (entry.positionSeconds > 0) {
          return '${(entry.watchedFraction * 100).round()}% visionné · $size';
        }
        return size;
      case DownloadStatus.downloading:
        final total = entry.bytesTotal > 0
            ? ' sur ${formatBytes(entry.bytesTotal)}'
            : '';
        return '${formatBytes(entry.bytesReceived)}$total téléchargés';
      case DownloadStatus.queued:
        return 'En attente';
      case DownloadStatus.paused:
        return 'En pause · ${formatBytes(entry.bytesReceived)} téléchargés';
      case DownloadStatus.failed:
        return entry.error ?? 'Échec du téléchargement';
    }
  }

  void _play(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(
          name: SearchRouteObserver.playerRouteName,
        ),
        builder: (_) => PlayerScreen(
          media: entry.toHomeMediaItem(),
          seasonNumber: entry.seasonNumber,
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final OfflineDownload entry;
  final double width;
  final double height;
  final DownloadManager manager;

  const _Thumbnail({
    required this.entry,
    required this.width,
    required this.height,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    // Le fichier local et rien d'autre : une URL distante ne s'afficherait pas
    // là où cet écran sert le plus.
    final path = manager.localPosterPath(entry.mediaId);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path != null)
              localFileImage(path)
            else
              const ColoredBox(color: AppColors.surfaceElevated),
            if (entry.isCompleted && entry.isFinished)
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 13, color: AppColors.success),
                ),
              ),
            if (entry.isCompleted &&
                !entry.isFinished &&
                entry.watchedFraction > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: entry.watchedFraction,
                  minHeight: 3,
                  backgroundColor: Colors.black.withValues(alpha: 0.4),
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.progress),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RowActions extends StatelessWidget {
  final OfflineDownload entry;

  const _RowActions({required this.entry});

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManager>();
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded,
          color: AppColors.textSecondary, size: 20),
      color: AppColors.surfaceElevated,
      onSelected: (value) async {
        switch (value) {
          case 'pause':
            await manager.pause(entry.mediaId);
          case 'resume':
            await manager.resume(entry.mediaId);
          case 'retry':
            await manager.resume(entry.mediaId);
          case 'delete':
            final confirmed = await confirmDeleteDownload(context, entry);
            if (confirmed) await manager.delete(entry.mediaId);
        }
      },
      itemBuilder: (context) => [
        if (entry.isActive)
          const PopupMenuItem(value: 'pause', child: Text('Mettre en pause')),
        if (entry.status == DownloadStatus.paused)
          const PopupMenuItem(value: 'resume', child: Text('Reprendre')),
        if (entry.status == DownloadStatus.failed)
          const PopupMenuItem(value: 'retry', child: Text('Réessayer')),
        const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
      ],
    );
  }
}
