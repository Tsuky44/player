import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../models/shared_show.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/detail_actions.dart';
import '../../widgets/global/detail_facts_section.dart';
import '../../widgets/global/detail_metadata.dart';
import '../../widgets/global/episode_tile.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../library/widgets/season_tabs.dart';
import '../../l10n/tr.dart';

/// La page du lien d'une saison ou d'une série : la fiche qu'un compte voit
/// (ADR-0037 §10), montée avec les mêmes composants — l'en-tête et son
/// synopsis, « Reprendre », les saisons en onglets, les épisodes avec leur
/// image et leur avancement.
///
/// Passive : [show] porte déjà l'avancement gardé sur l'appareil, et la page
/// du lien ouvre l'épisode choisi. Ce qui suppose un compte n'y est pas —
/// marquer vu, télécharger, partager, demander une saison.
class SharedLinkShowView extends StatefulWidget {
  const SharedLinkShowView({
    super.key,
    required this.show,
    required this.onPlay,
    this.openingId,
    this.error,
    this.onClose,
  });

  final SharedShow show;

  /// Nul pendant qu'un épisode s'ouvre : un seul à la fois.
  final ValueChanged<HomeMediaItem>? onPlay;

  /// L'épisode en train de s'ouvrir, qui montre l'attente.
  final int? openingId;

  /// Une ouverture refusée (réseau, trop de lectures), à corriger sans
  /// quitter la page.
  final String? error;

  /// Ferme la page, dans l'app installée. Nul sur le web, où il n'y a rien
  /// derrière elle.
  final VoidCallback? onClose;

  @override
  State<SharedLinkShowView> createState() => _SharedLinkShowViewState();
}

class _SharedLinkShowViewState extends State<SharedLinkShowView> {
  /// La saison choisie à la main. Tant qu'il n'y en a pas, la page suit celle
  /// de l'épisode à reprendre — qui avance quand on revient du lecteur.
  int? _pickedSeasonId;

  Media? _selectedSeason(List<Media> seasons) {
    if (seasons.isEmpty) return null;
    final wanted =
        _pickedSeasonId ?? widget.show.resumeEpisode?.media.parentId;
    return seasons.firstWhere((s) => s.id == wanted,
        orElse: () => seasons.first);
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final details = show.info.details;
    final seasons = show.seasons;
    final season = _selectedSeason(seasons);
    final episodes = season == null
        ? const <HomeMediaItem>[]
        : show.episodesOf(season.id);
    final resume = show.resumeEpisode;
    final resuming = show.isResuming;
    final onPlay = widget.onPlay;
    final opening = widget.openingId != null;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: DetailBackdropHeader(
              fallback: show.show,
              details: details,
              metadata: buildMetadataChips(
                type: MediaType.show,
                releaseDate: show.show.releaseDate,
                rating: details?.voteAverage ?? 0,
                // Les saisons que le lien ouvre, pas celles que la série
                // compte : annoncer cinq saisons devant une seule tromperait.
                seasons: seasons.length,
                genres: details?.genres ?? const [],
              ),
              onBack: widget.onClose,
              emptyOverviewLabel: tr('Partagé avec vous sur Onyx.'),
              actions: DetailActions(
                playLabel: detailPlayLabel(
                  resuming: resuming,
                  episode: resume?.media,
                ),
                onPlay: resume == null || onPlay == null
                    ? null
                    : () => onPlay(resume),
                progress: resuming ? resume!.percentWatched : null,
                progressLabel: resuming
                    ? formatRemaining(resume!.effectiveDuration -
                        resume.currentPositionSeconds)
                    : null,
              ),
            ),
          ),
          if (widget.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: AppLayout.pageInsets(context, top: 16),
                child: Text(
                  widget.error!,
                  style: const TextStyle(color: AppColors.error),
                ),
              ),
            ),
          if (seasons.length > 1)
            SliverToBoxAdapter(
              child: Padding(
                padding: AppLayout.pageInsets(context, top: 24, bottom: 8),
                child: SeasonTabs(
                  seasons: seasons,
                  selected: season,
                  onSelected: (picked) =>
                      setState(() => _pickedSeasonId = picked.id),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, top: 16, bottom: 8),
              child: Row(
                children: [
                  Text(tr('Épisodes'), style: detailSectionTitleStyle(context)),
                  const SizedBox(width: 12),
                  if (opening)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (episodes.isNotEmpty)
                    Text(
                      '${episodes.length} '
                      'disponible${episodes.length > 1 ? 's' : ''}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textMuted,
                          ),
                    ),
                ],
              ),
            ),
          ),
          if (episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
                child: Text(
                  tr('Aucun épisode n’est disponible pour le moment.'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final episode = episodes[index];
                  return EpisodeTile(
                    episode: episode,
                    episodeNumber: episode.media.episodeNumber ?? index + 1,
                    showTitle: show.info.title,
                    seasonNumber: season?.seasonNumber,
                    allowDownload: false,
                    onTap: onPlay == null ? null : () => onPlay(episode),
                  );
                },
                childCount: episodes.length,
              ),
            ),
          // Montrée, pas ouverte : la fiche d'un acteur mène au reste de la
          // médiathèque, que le lien n'ouvre pas.
          if (details?.cast.isNotEmpty ?? false)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 32),
                child: CastSection(cast: details!.cast),
              ),
            ),
          SliverToBoxAdapter(child: DetailFactsSection(details: details)),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
