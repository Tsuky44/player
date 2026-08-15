import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/media_request.dart';
import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/api_client.dart';
import '../../services/media_details_cache.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/episode_tile.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../../widgets/global/metadata_fix_sheet.dart';
import '../player/player_screen.dart';
import '../requests/widgets/season_selector_dialog.dart';
import '../../navigation/search_route_observer.dart';
import 'widgets/missing_season_banner.dart';

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
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _show = widget.show;
    // Paint from the shared cache before the first frame when this show has
    // been opened before this session, so the header does not rebuild from an
    // empty state on every visit.
    _adopt(MediaDetailsCache.peek(_show.id));
    _loadDetails();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadShowData());
  }

  /// Folds a details payload into the page state. The server may answer with a
  /// different id than we asked for — it resolves duplicate show rows to a
  /// canonical one — so the local handle adopts the resolved id.
  void _adopt(MediaDetails? details) {
    if (details == null) return;
    _details = details;
    _show = Media(
      id: details.id,
      type: _show.type,
      title: details.title.isNotEmpty ? details.title : _show.title,
      duration: _show.duration,
      posterUrl: details.posterUrl ?? _show.posterUrl,
      overview: details.overview ?? _show.overview,
      releaseDate: details.releaseDate ?? _show.releaseDate,
      tmdbId: details.tmdbId ?? _show.tmdbId,
      createdAt: _show.createdAt,
    );
  }

  Future<void> _loadDetails({bool forceRefresh = false}) async {
    // Only claim to be loading when there is nothing on screen yet; a
    // background revalidation must not swap the synopsis for a spinner.
    if (_details == null) setState(() => _loadingDetails = true);
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final details = await MediaDetailsCache.load(
        api,
        _show.id,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      final resolvedId = details.id;
      setState(() => _adopt(details));
      if (resolvedId != widget.show.id) {
        await _loadShowData();
      }
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
        // Virtual seasons have id=0 — match by season number from the episode.
        if (resumeSeason == null) {
          final seasonNum = resumeEpisode?.media.effectiveSeasonNumber;
          if (seasonNum != null) {
            for (final season in lp.seasons) {
              if (season.effectiveSeasonNumber == seasonNum) {
                resumeSeason = season;
                break;
              }
            }
          }
        }
      }
    } catch (_) {
      // Fallback: first available season.
    }

    final seasonToLoad = resumeSeason ??
        (lp.seasons.isNotEmpty
            ? lp.seasons.firstWhere(
                (s) => s.isAvailable,
                orElse: () => lp.seasons.first,
              )
            : null);
    if (seasonToLoad != null) {
      await lp.loadEpisodes(showId: _show.id, season: seasonToLoad);
    }

    if (!mounted) return;
    setState(() {
      _resumeEpisode = resumeEpisode;
      _selectedSeason = seasonToLoad;
    });
  }

  /// Seasons the server does not hold and MediaHub has not been asked for yet.
  List<Media> _requestableSeasons(List<Media> seasons) =>
      seasons.where((s) => s.canRequest).toList();

  Future<void> _requestSeasons(List<int> seasonNumbers) async {
    if (_requesting || seasonNumbers.isEmpty) return;
    setState(() => _requesting = true);

    final library = Provider.of<LibraryProvider>(context, listen: false);
    try {
      await library.requestSeasons(show: _show, seasonNumbers: seasonNumbers);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demande envoyée à MediaHub.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’envoyer la demande.')),
      );
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  /// Maps a library season onto the status vocabulary of the request dialog.
  /// The dialog only lets `unknown` be selected, so anything the server did not
  /// mark requestable — including an unreachable MediaHub — is reported as a
  /// state that cannot be picked.
  RequestMediaStatus _dialogStatusOf(Media season) {
    if (!season.canRequest) {
      return RequestMediaStatus.values.firstWhere(
        (status) =>
            status.name == season.requestStatus &&
            status != RequestMediaStatus.unknown,
        orElse: () => RequestMediaStatus.available,
      );
    }
    return RequestMediaStatus.unknown;
  }

  Future<void> _openSeasonSelector(List<Media> seasons) async {
    final picked = await SeasonSelectorDialog.show(
      context,
      title: _show.title,
      seasons: [
        for (final season in seasons)
          if ((season.effectiveSeasonNumber ?? 0) > 0)
            RequestSeason(
              number: season.effectiveSeasonNumber!,
              name: season.title,
              episodeCount: season.episodeCount ?? 0,
              posterPath: null,
              status: _dialogStatusOf(season),
            ),
      ],
    );
    if (picked != null && picked.isNotEmpty) {
      await _requestSeasons(picked);
    }
  }

  /// Lowest-numbered episode that actually has a file, ignoring the TMDB-only
  /// placeholders a partially indexed season can contain.
  static HomeMediaItem? _firstPlayable(List<HomeMediaItem> episodes) {
    for (final episode in episodes) {
      if (episode.isAvailable) return episode;
    }
    return null;
  }

  void _playEpisode(HomeMediaItem episode) {
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
  }

  Future<void> _onSeasonChanged(Media season) async {
    setState(() => _selectedSeason = season);
    await Provider.of<LibraryProvider>(context, listen: false)
        .loadEpisodes(showId: _show.id, season: season);
  }

  Future<void> _toggleEpisodeWatched(HomeMediaItem episode, bool watched) async {
    if (!episode.isAvailable) return;
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

  Future<({String? folder, String? episode})> _fetchLocalLibraryContext(
    ApiClient api,
    LibraryProvider lp,
  ) async {
    String? folder = _sampleReleaseNameFromLibrary(lp);
    String? episode;
    for (final ep in [
      if (_resumeEpisode != null) _resumeEpisode!,
      ...lp.episodes,
    ]) {
      final path = ep.media.filePath;
      if (path == null || path.isEmpty) continue;
      episode ??= path.split(RegExp(r'[\\/]+')).last;
    }
    try {
      final details = await api.getMediaDetails(_show.id);
      if (mounted) setState(() => _details = details);
      final f = details.localFolder?.trim();
      final e = details.localEpisodeFile?.trim();
      if (f != null && f.isNotEmpty) folder = f;
      if (e != null && e.isNotEmpty) episode = e;
    } catch (_) {}
    return (folder: folder, episode: episode);
  }

  String? _sampleReleaseNameFromLibrary(LibraryProvider lp) {
    for (final ep in [
      if (_resumeEpisode != null) _resumeEpisode!,
      ...lp.episodes,
    ]) {
      final path = ep.media.filePath;
      if (path == null || path.isEmpty) continue;
      final segments = path.replaceAll('\\', '/').split('/')
        ..removeWhere((s) => s.trim().isEmpty);
      if (segments.length < 2) continue;
      for (var i = segments.length - 2; i >= 0; i--) {
        final part = segments[i].trim();
        if (part.isEmpty) continue;
        final lower = part.toLowerCase();
        if (lower.startsWith('season ') || lower.startsWith('saison ')) {
          continue;
        }
        if (RegExp(r's\d{1,2}e\d{1,3}', caseSensitive: false).hasMatch(part)) {
          continue;
        }
        return part;
      }
    }
    return null;
  }

  Future<void> _reloadShowAfterMetadataChange() async {
    final library = Provider.of<LibraryProvider>(context, listen: false);
    final home = Provider.of<HomeProvider>(context, listen: false);
    // The cached payload now describes the wrong title — drop it everywhere,
    // not just on this page, or the player would still show the old logo.
    MediaDetailsCache.invalidate(_show.id);
    await _loadDetails(forceRefresh: true);
    await library.loadSeasons(_show.id);
    if (_selectedSeason != null) {
      await library.loadEpisodes(
        showId: _show.id,
        season: _selectedSeason!,
      );
    }
    await home.loadHome(silent: true);
  }

  Future<void> _autoRedetect() async {
    final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
    final lp = Provider.of<LibraryProvider>(context, listen: false);
    final local = await _fetchLocalLibraryContext(api, lp);
    if (!mounted) return;

    final folderLine = local.folder?.isNotEmpty == true
        ? local.folder!
        : 'dossier inconnu';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Relancer la détection'),
        content: Text(
          'TMDB sera recherché à partir du dossier local :\n\n'
          '$folderLine\n\n'
          'L’affiche et les métadonnées de cette série seront remplacées.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Relancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await api.redetectMediaMetadata(_show.id);
      if (!mounted) return;
      setState(() {
        _show = updated;
        _details = null;
      });
      await _reloadShowAfterMetadataChange();
      messenger.showSnackBar(
        const SnackBar(content: Text('Détection automatique terminée')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Détection impossible — essayez le choix manuel TMDB'),
        ),
      );
    }
  }

  Future<void> _rematch() async {
    final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
    final lp = Provider.of<LibraryProvider>(context, listen: false);
    final local = await _fetchLocalLibraryContext(api, lp);
    if (!mounted) return;

    final searchSeed = local.folder ?? local.episode ?? _show.title;

    final choice = await MetadataFixSheet.show(
      context,
      api: api,
      initialQuery: searchSeed,
      type: MediaType.show,
      localFolder: local.folder,
      localEpisodeFile: local.episode,
    );

    if (choice == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated =
          await api.rematchMediaMetadata(_show.id, tmdbId: choice.tmdbId);
      if (!mounted) return;
      setState(() {
        _show = updated;
        _details = null;
      });
      await _reloadShowAfterMetadataChange();
      messenger.showSnackBar(
        const SnackBar(content: Text('Fiche série mise à jour')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Impossible de mettre à jour la fiche'),
        ),
      );
    }
  }

  void _onMetadataMenuSelected(String value) {
    switch (value) {
      case 'auto':
        _autoRedetect();
        break;
      case 'manual':
        _rematch();
        break;
    }
  }

  Media? _resolveSelectedSeason(List<Media> seasons) {
    final selected = _selectedSeason;
    if (selected == null || seasons.isEmpty) return null;
    for (final s in seasons) {
      if (identical(s, selected) || s.id == selected.id && s.id > 0) {
        return s;
      }
      if (s.effectiveSeasonNumber != null &&
          s.effectiveSeasonNumber == selected.effectiveSeasonNumber) {
        return s;
      }
    }
    return selected;
  }

  @override
  Widget build(BuildContext context) {
    final lp = Provider.of<LibraryProvider>(context);
    final selectedSeason = _resolveSelectedSeason(lp.seasons);
    final resumeEp =
        _resumeEpisode != null && _resumeEpisode!.isAvailable ? _resumeEpisode : null;
    final seasonsCount =
        lp.seasons.isNotEmpty ? lp.seasons.length : (_details?.numberOfSeasons ?? 0);
    final availableCount = lp.episodes.where((e) => e.isAvailable).length;
    final totalCount = lp.episodes.length;
    final selectedMissing = selectedSeason != null &&
        !selectedSeason.isAvailable &&
        (selectedSeason.effectiveSeasonNumber ?? 0) > 0;

    // Nothing watched yet: offer the first playable episode of the season on
    // screen, which on opening the page is season 1 — so a show never started
    // gets a plain "watch episode 1" entry point.
    final firstEpisode = resumeEp == null ? _firstPlayable(lp.episodes) : null;

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
              actions: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (resumeEp != null) ...[
                    ElevatedButton.icon(
                      onPressed: () => _playEpisode(resumeEp),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        resumeEp.currentPositionSeconds > 0 && !resumeEp.isFinished
                            ? 'REPRENDRE'
                            : 'LECTURE',
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else if (firstEpisode != null) ...[
                    ElevatedButton.icon(
                      onPressed: () => _playEpisode(firstEpisode),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('REGARDER'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  PopupMenuButton<String>(
                    tooltip: 'Métadonnées série',
                    onSelected: _onMetadataMenuSelected,
                    icon: const Icon(
                      Icons.edit_note_rounded,
                      color: AppColors.textSecondary,
                    ),
                    color: AppColors.surfaceElevated,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'auto',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.auto_fix_high_outlined),
                          title: Text('Relancer la détection auto'),
                          subtitle: Text(
                            'À partir du dossier / fichiers locaux',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'manual',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.search_rounded),
                          title: Text('Choisir sur TMDB'),
                          subtitle: Text(
                            'Correction manuelle de l’affiche',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
                  onTapMember: (member) =>
                      openPerson(context, member.tmdbId, name: member.name),
                ),
              ),
            ),

          if (lp.isLoadingSeasons)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (lp.seasons.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: AppLayout.pageInsets(context, top: 24, bottom: 8),
                // A DropdownButton forces its menu to the anchor's width, so a
                // compact button clipped the "· manquante" annotations. A popup
                // menu sizes itself to its own content instead.
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PopupMenuButton<Media>(
                    tooltip: 'Choisir une saison',
                    position: PopupMenuPosition.under,
                    offset: const Offset(0, 6),
                    padding: EdgeInsets.zero,
                    color: AppColors.surfaceElevated,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppColors.glassBorder),
                    ),
                    onSelected: _onSeasonChanged,
                    itemBuilder: (_) => lp.seasons
                        .map((s) => PopupMenuItem<Media>(
                              value: s,
                              child: _SeasonMenuLabel(
                                season: s,
                                selected: identical(s, selectedSeason),
                              ),
                            ))
                        .toList(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            selectedSeason == null
                                ? 'Saison'
                                : seasonLabel(selectedSeason),
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: selectedSeason == null
                                      ? AppColors.textSecondary
                                      : AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.expand_more_rounded,
                              size: 18, color: AppColors.textSecondary),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          if (selectedMissing)
            SliverToBoxAdapter(
              child: Padding(
                padding: AppLayout.pageInsets(context, top: 8),
                child: MissingSeasonBanner(
                  season: selectedSeason,
                  requestableCount: _requestableSeasons(lp.seasons).length,
                  submitting: _requesting,
                  onRequest: () => _requestSeasons(
                    [selectedSeason.effectiveSeasonNumber!],
                  ),
                  onRequestMore: () => _openSeasonSelector(lp.seasons),
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              padding: AppLayout.pageInsets(context, top: 16, bottom: 8),
              child: Row(
                children: [
                  Text(
                    'Épisodes',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (totalCount > 0) ...[
                    const SizedBox(width: 12),
                    Text(
                      '$availableCount/$totalCount disponibles',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textMuted,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (lp.isLoadingEpisodes)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (lp.episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(AppLayout.pagePadding(context)),
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
                    episodeNumber:
                        episode.media.episodeNumber ?? index + 1,
                    onToggleWatched: episode.isAvailable
                        ? (watched) => _toggleEpisodeWatched(episode, watched)
                        : null,
                    onTap:
                        episode.isAvailable ? () => _playEpisode(episode) : null,
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

/// Shared by the closed button and the menu entries so both read the same.
String seasonLabel(Media season) {
  final number = season.effectiveSeasonNumber;
  return number != null && number > 0 ? 'Saison $number' : season.title;
}

/// One entry of the season picker. Seasons the server does not hold are marked
/// in the menu itself, so the state is visible before selecting them.
class _SeasonMenuLabel extends StatelessWidget {
  final Media season;
  final bool selected;

  const _SeasonMenuLabel({required this.season, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final label = seasonLabel(season);
    final weight = selected ? FontWeight.w700 : FontWeight.w500;

    if (season.isAvailable) {
      return Text(
        label,
        style: TextStyle(color: AppColors.textPrimary, fontWeight: weight),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          season.isRequested
              ? Icons.hourglass_top_rounded
              : Icons.cloud_off_outlined,
          size: 15,
          color: season.isRequested ? AppColors.accentMuted : AppColors.textMuted,
        ),
        const SizedBox(width: 6),
        Text(
          season.isRequested ? '$label · demandée' : '$label · manquante',
          style: TextStyle(
            color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            fontWeight: weight,
          ),
        ),
      ],
    );
  }
}
