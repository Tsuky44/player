import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../models/offline_download.dart';
import '../../services/download_manager.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../widgets/global/bulk_download_delete.dart';
import '../../widgets/global/local_file_image.dart';

/// L'en-tête d'une série, nourri par la fiche rapatriée avec ses épisodes.
///
/// Sans elle il n'y aurait qu'un titre : c'est la fiche qui apporte l'affiche,
/// l'année, les genres et le synopsis — soit tout ce qui permet de reconnaître
/// une série sans serveur pour la décrire.
///
/// Il porte aussi la sortie de la série entière : libérer de la place se
/// faisait épisode par épisode, par le menu de chaque ligne.
class DownloadShowHeader extends StatefulWidget {
  final String title;
  final int? infoId;
  final List<OfflineDownload> entries;

  /// Faux pour le regroupement des films, qui n'est pas une chose qu'on
  /// supprime d'un bloc.
  final bool deletable;

  const DownloadShowHeader({
    super.key,
    required this.title,
    required this.infoId,
    required this.entries,
    this.deletable = true,
  });

  @override
  State<DownloadShowHeader> createState() => _DownloadShowHeaderState();
}

class _DownloadShowHeaderState extends State<DownloadShowHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (!widget.deletable) return body;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: body),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () => confirmDeleteDownloads(
            context,
            what: '« ${widget.title} »',
            entries: widget.entries,
          ),
          tooltip: 'Supprimer la série',
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
          color: AppColors.textSecondary,
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
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
    final count = widget.entries.length;
    final parts = <String>[
      '$count ${count > 1 ? 'éléments' : 'élément'}',
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

/// L'intertitre d'une saison, dans une série qui en a plusieurs sur
/// l'appareil : de quoi voir ce qu'elle pèse, et la supprimer d'un geste.
class DownloadSeasonHeader extends StatelessWidget {
  final int? seasonNumber;
  final List<OfflineDownload> entries;

  const DownloadSeasonHeader({
    super.key,
    required this.seasonNumber,
    required this.entries,
  });

  /// Le libellé d'une saison, « spéciaux » compris : c'est la saison 0 chez
  /// TMDB, et « Saison 0 » ne dit rien à personne.
  static String labelFor(int? seasonNumber) => switch (seasonNumber) {
        null => 'Sans saison',
        0 => 'Épisodes spéciaux',
        final n => 'Saison $n',
      };

  @override
  Widget build(BuildContext context) {
    final label = labelFor(seasonNumber);
    final what = seasonNumber == null || seasonNumber == 0
        ? 'ces épisodes'
        : 'la saison $seasonNumber';
    final count = entries.length;
    final bytes = entries.fold<int>(0, (sum, e) => sum + e.bytesReceived);
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$count épisode${count > 1 ? 's' : ''} · ${formatBytes(bytes)}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ),
        IconButton(
          onPressed: () => confirmDeleteDownloads(
            context,
            what: what,
            entries: entries,
          ),
          tooltip: 'Supprimer $what',
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          visualDensity: VisualDensity.compact,
          color: AppColors.textMuted,
        ),
      ],
    );
  }
}
