import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/episode_tile.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../player/player_screen.dart';
import '../../navigation/search_route_observer.dart';

class ShowDetailScreen extends StatefulWidget {
  final Media show;

  const ShowDetailScreen({super.key, required this.show});

  @override
  State<ShowDetailScreen> createState() => _ShowDetailScreenState();
}

class _ShowDetailScreenState extends State<ShowDetailScreen> {
  late Media _show;
  MediaDetails? _details;
  bool _loadingDetails = false;
  Media? _selectedSeason;
  HomeMediaItem? _resumeEpisode;

  @override
  void initState() {
    super.initState();
    _show = widget.show;
    _loadDetails();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadShowData());
  }

  Future<void> _loadDetails() async {
    setState(() => _loadingDetails = true);
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final details = await api.getMediaDetails(_show.id);
      if (!mounted) return;
      setState(() {
        _details = details;
        _show = Media(
          id: _show.id,
          type: _show.type,
          title: details.title.isNotEmpty ? details.title : _show.title,
          duration: _show.duration,
          posterUrl: details.posterUrl ?? _show.posterUrl,
          overview: details.overview ?? _show.overview,
          releaseDate: details.releaseDate ?? _show.releaseDate,
          tmdbId: details.tmdbId ?? _show.tmdbId,
          createdAt: _show.createdAt,
        );
      });
    } catch (_) {
      // Keep local data on failure.
    } finally {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  Future<void> _loadShowData() async {
    final lp = Provider.of<LibraryProvider>(context, listen: false);
    lp.clearSeasonsAndEpisodes();
    setState(() {
      _selectedSeason = null;
      _resumeEpisode = null;
    });

    await lp.loadSeasons(_show.id);

    HomeMediaItem? resumeEpisode;
    Media? resumeSeason;
    try {
      final resume = await lp.apiClient.getShowResumeEpisode(_show.id);
      if (resume.hasEpisode && resume.episode != null) {
        resumeEpisode = resume.episode;
        if (resume.seasonId != null) {
          for (final season in lp.seasons) {
            if (season.id == resume.seasonId) {
              resumeSeason = season;
              break;
            }
          }
        }
      }
    } catch (_) {
      // Fallback: first unwatched episode in first season.
    }

    final seasonToLoad = resumeSeason ?? (lp.seasons.isNotEmpty ? lp.seasons.first : null);
    if (seasonToLoad != null) {
      await lp.loadEpisodes(seasonToLoad.id);
    }

    if (!mounted) return;
    setState(() {
      _resumeEpisode = resumeEpisode;
      _selectedSeason = seasonToLoad;
    });
  }

  Future<void> _onSeasonChanged(Media season) async {
    setState(() => _selectedSeason = season);
    await Provider.of<LibraryProvider>(context, listen: false).loadEpisodes(season.id);
  }

  Future<void> _toggleEpisodeWatched(HomeMediaItem episode, bool watched) async {
    final library = Provider.of<LibraryProvider>(context, listen: false);
    final home = Provider.of<HomeProvider>(context, listen: false);
    try {
      await library.setMediaWatched(episode.media.id, watched);
      await home.loadHome(silent: true);
      if (episode.media.id == _resumeEpisode?.media.id) {
        setState(() => _resumeEpisode = library.episodes.firstWhere(
              (e) => e.media.id == episode.media.id,
              orElse: () => episode,
            ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de mettre à jour le statut')),
        );
      }
    }
  }

  int? get _playerSeasonNumber => _selectedSeason?.effectiveSeasonNumber;

  @override
  Widget build(BuildContext context) {
    final lp = Provider.of<LibraryProvider>(context);
    final resumeEp = _resumeEpisode;
    final seasonsCount =
        lp.seasons.isNotEmpty ? lp.seasons.length : (_details?.numberOfSeasons ?? 0);

    final metadata = buildMetadataChips(
      type: MediaType.show,
      releaseDate: _details?.releaseDate ?? _show.releaseDate,
      rating: _details?.voteAverage ?? 0,
      seasons: seasonsCount,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: DetailBackdropHeader(
              fallback: _show,
              details: _details,
              metadata: metadata,
              onBack: () => Navigator.of(context).pop(),
              actions: resumeEp != null
                  ? ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            settings: const RouteSettings(
                              name: SearchRouteObserver.playerRouteName,
                            ),
                            builder: (_) => PlayerScreen(
                              media: resumeEp,
                              seasonNumber: _playerSeasonNumber,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        resumeEp.currentPositionSeconds > 0 && !resumeEp.isFinished
                            ? 'REPRENDRE'
                            : 'LECTURE',
                      ),
                    )
                  : null,
            ),
          ),

          SliverToBoxAdapter(
            child: DetailInfoSection(
              details: _details,
              fallbackOverview: _show.overview,
              emptyOverviewLabel: _loadingDetails
                  ? 'Chargement des informations…'
                  : 'Synopsis indisponible pour cette série.',
            ),
          ),

          if (_details?.cast.isNotEmpty ?? false)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: CastSection(
                  cast: _details!.cast,
                  onTapMember: (member) => openPerson(context, member.tmdbId, name: member.name),
                ),
              ),
            ),

          // Season selector
          if (lp.isLoadingSeasons)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (lp.seasons.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 24, 48, 8),
                child: Row(
                  children: [
                    Text(
                      'Saison',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(width: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<Media>(
                          value: _selectedSeason,
                          dropdownColor: AppColors.surfaceElevated,
                          icon: const Icon(Icons.expand_more_rounded, color: AppColors.textSecondary),
                          items: lp.seasons.map((s) {
                            return DropdownMenuItem(
                              value: s,
                              child: Text(
                                s.title,
                                style: const TextStyle(color: AppColors.textPrimary),
                              ),
                            );
                          }).toList(),
                          onChanged: (s) {
                            if (s != null) _onSeasonChanged(s);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Episodes
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 16, 48, 8),
              child: Text(
                'Épisodes',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),

          if (lp.isLoadingEpisodes)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (lp.episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Text(
                  'Aucun épisode pour cette saison.',
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
                  final episode = lp.episodes[index];
                  return EpisodeTile(
                    episode: episode,
                    episodeNumber: episode.media.episodeNumber ?? index + 1,
                    onToggleWatched: (watched) => _toggleEpisodeWatched(episode, watched),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          settings: const RouteSettings(
                            name: SearchRouteObserver.playerRouteName,
                          ),
                          builder: (_) => PlayerScreen(
                            media: episode,
                            seasonNumber: _playerSeasonNumber,
                          ),
                        ),
                      );
                    },
                  );
                },
                childCount: lp.episodes.length,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
