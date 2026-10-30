import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/media_details_cache.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/format.dart';
import '../../utils/on_screen.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/detail_actions.dart';
import '../../widgets/global/detail_backdrop_header.dart';
import '../../widgets/global/detail_metadata.dart';
import '../../widgets/global/episode_tile.dart';
import '../../widgets/global/live_progress_state.dart';
import '../../widgets/global/season_download_button.dart';
import '../../widgets/global/season_watched_button.dart';
import 'show_episode_actions.dart';
import 'widgets/season_preview.dart';
import 'widgets/season_tabs.dart';

/// La page d'une saison : son affiche et son résumé sur le fond de la série,
/// puis ses épisodes. On y arrive par la fiche qui s'ouvre au survol d'un
/// onglet de saison ([SeasonHoverPreview]).
///
/// Elle tient sa propre liste d'épisodes ([LibraryProvider.cachedEpisodes]) :
/// la fiche série restée dessous garde l'onglet qu'elle montrait.
class SeasonDetailScreen extends StatefulWidget {
  final Media show;
  final Media season;

  const SeasonDetailScreen({
    super.key,
    required this.show,
    required this.season,
  });

  @override
  State<SeasonDetailScreen> createState() => _SeasonDetailScreenState();
}

class _SeasonDetailScreenState extends State<SeasonDetailScreen>
    with OnScreenState, LiveProgressState {
  MediaDetails? _showDetails;
  ShowResumeResponse? _resume;
  bool _loadingEpisodes = false;
  bool _failed = false;
  bool _updatingWatched = false;

  Media get _show => widget.show;
  Media get _season => widget.season;
  int? get _seasonNumber => _season.effectiveSeasonNumber;

  @override
  void initState() {
    super.initState();
    final library = Provider.of<LibraryProvider>(context, listen: false);
    // Ce que la fiche série a déjà chargé peint la première image ; le
    // réseau ne fait que la confirmer.
    _showDetails = MediaDetailsCache.peek(_show.id);
    _resume = library.cachedResume(_show.id);
    _loadingEpisodes = library.cachedEpisodes(_show.id, _season) == null;
    _refresh();
    _loadShowDetails();
  }

  Future<void> _loadShowDetails() async {
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final details = await MediaDetailsCache.load(api, _show.id);
      if (mounted && !identical(details, _showDetails)) {
        setState(() => _showDetails = details);
      }
    } catch (_) {
      // Sans la fiche de la série, l'en-tête garde l'affiche de la saison sur
      // un fond uni : la page reste lisible.
    }
  }

  /// Épisodes et point de reprise, relus à chaque retour sur la page.
  Future<void> _refresh() async {
    final library = Provider.of<LibraryProvider>(context, listen: false);
    final resumeRequest = library.loadResume(_show.id);
    try {
      await library.refreshEpisodes(showId: _show.id, season: _season);
      if (mounted && _failed) setState(() => _failed = false);
    } catch (_) {
      // Une liste déjà en mémoire reste affichée ; sans elle, la page le dit.
      if (mounted) setState(() => _failed = true);
    }
    // Une reprise introuvable garde la dernière réponse connue.
    final resume = await resumeRequest;
    if (!mounted) return;
    setState(() {
      if (resume != null) _resume = resume;
      _loadingEpisodes = false;
    });
  }

  @override
  void onProgressChanged() {
    if (_updatingWatched) return;
    _refresh();
  }

  /// L'épisode où la série reprend, s'il est dans cette saison — tel que la
  /// liste le connaît, avec sa progression la plus fraîche.
  HomeMediaItem? _resumeIn(List<HomeMediaItem> episodes) {
    final resume = _resume;
    final episode = resume != null && resume.hasEpisode ? resume.episode : null;
    if (episode == null) return null;
    final inSeason = _season.id > 0 && resume!.seasonId == _season.id ||
        episode.media.effectiveSeasonNumber == _seasonNumber;
    if (!inSeason) return null;
    for (final item in episodes) {
      if (item.media.id == episode.media.id) {
        return item.isAvailable ? item : null;
      }
    }
    return episode.isAvailable ? episode : null;
  }

  void _play(HomeMediaItem episode, List<HomeMediaItem> episodes) =>
      playShowEpisode(
        context,
        episode,
        siblings: episodes,
        seasonNumber: _seasonNumber,
      );

  Future<void> _setSeasonWatched(
      List<HomeMediaItem> episodes, bool watched) async {
    if (_updatingWatched || episodes.isEmpty) return;
    setState(() => _updatingWatched = true);
    try {
      final ok = await setSeasonEpisodesWatched(context, episodes, watched);
      if (ok && mounted) await _refresh();
    } finally {
      if (mounted) setState(() => _updatingWatched = false);
    }
  }

  /// L'en-tête des fiches, habillé pour la saison : le fond et le nom de la
  /// série, l'affiche et le résumé de la saison.
  MediaDetails? _headerDetails() {
    final show = _showDetails;
    if (show == null) return null;
    final seasonPoster = _season.posterUrl;
    return MediaDetails(
      id: show.id,
      type: MediaType.season,
      title: seasonLabel(_season),
      overview: _season.overview,
      posterUrl: seasonPoster != null && seasonPoster.isNotEmpty
          ? seasonPoster
          : show.posterUrl,
      backdropUrl: show.backdropUrl,
      releaseDate: _season.releaseDate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = Provider.of<LibraryProvider>(context);
    final episodes = library.cachedEpisodes(_show.id, _season) ?? const [];
    final availableCount = episodes.where((e) => e.isAvailable).length;

    final resumeEp = _resumeIn(episodes);
    HomeMediaItem? firstEpisode;
    if (resumeEp == null) {
      for (final episode in episodes) {
        if (episode.isAvailable) {
          firstEpisode = episode;
          break;
        }
      }
    }
    final playTarget = resumeEp ?? firstEpisode;
    final resumeInProgress = resumeEp != null &&
        resumeEp.currentPositionSeconds > 0 &&
        !resumeEp.isFinished;
    final seasonPoster = _season.posterUrl;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        scrollCacheExtent: AppLayout.imageCacheExtent(context),
        slivers: [
          SliverToBoxAdapter(
            child: DetailBackdropHeader(
              fallback: Media(
                id: _season.id,
                type: MediaType.season,
                title: seasonLabel(_season),
                duration: 0,
                posterUrl: seasonPoster != null && seasonPoster.isNotEmpty
                    ? seasonPoster
                    : _show.posterUrl,
                overview: _season.overview,
                releaseDate: _season.releaseDate,
                createdAt: _season.createdAt,
              ),
              details: _headerDetails(),
              eyebrow: _show.title,
              metadata: [
                for (final fact in seasonFacts(
                  _season,
                  episodeCount: episodes.isNotEmpty ? episodes.length : null,
                ))
                  MetadataText(fact),
              ],
              loading: _showDetails == null,
              emptyOverviewLabel: tr('Pas de résumé pour cette saison.'),
              onBack: () => Navigator.of(context).pop(),
              actions: DetailActions(
                playLabel: detailPlayLabel(
                  resuming: resumeInProgress,
                  episode: playTarget?.media,
                  seasonOverride: _seasonNumber,
                ),
                onPlay: playTarget == null
                    ? null
                    : () => _play(playTarget, episodes),
                autofocusPlay: TvMode.isTv,
                progress: resumeInProgress ? resumeEp.percentWatched : null,
                progressLabel: resumeInProgress
                    ? formatRemaining(resumeEp.effectiveDuration -
                        resumeEp.currentPositionSeconds)
                    : null,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, top: 24, bottom: 8),
              child: Row(
                children: [
                  Text(tr('Épisodes'), style: detailSectionTitleStyle(context)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      episodes.isEmpty
                          ? ''
                          : tr('{0}/{1} disponibles',
                              [availableCount, episodes.length]),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textMuted,
                          ),
                    ),
                  ),
                  SeasonDownloadButton(
                    episodes: episodes,
                    showTitle: _show.title,
                    showId: _show.id,
                    showPosterUrl: _show.posterUrl,
                    seasonNumber: _seasonNumber,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SeasonWatchedButton(
                  episodes: episodes,
                  busy: _updatingWatched,
                  onSetWatched: _setSeasonWatched,
                ),
              ),
            ),
          ),
          if (_loadingEpisodes && episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
                child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
                child: Text(
                  _failed
                      ? tr('Impossible de charger les épisodes.')
                      : tr('Aucun épisode pour cette saison.'),
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
                    showTitle: _show.title,
                    showId: _show.id,
                    showPosterUrl: _show.posterUrl,
                    seasonNumber: _seasonNumber,
                    onToggleWatched: episode.isAvailable
                        ? (watched) async {
                            await setEpisodeWatched(context, episode, watched);
                          }
                        : null,
                    onTap: episode.isAvailable
                        ? () => _play(episode, episodes)
                        : null,
                  );
                },
                childCount: episodes.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
