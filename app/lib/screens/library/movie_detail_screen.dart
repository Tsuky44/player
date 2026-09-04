import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../services/media_details_cache.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../../widgets/global/media_download_button.dart';
import '../../widgets/global/metadata_fix_sheet.dart';
import '../../widgets/global/watched_action_button.dart';
import '../../navigation/search_route_observer.dart';
import '../player/player_screen.dart';

class MovieDetailScreen extends StatefulWidget {
  final HomeMediaItem? movieItem;
  final Media? movie;

  const MovieDetailScreen({
    super.key,
    this.movieItem,
    this.movie,
  }) : assert(movieItem != null || movie != null);

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Media _media;
  MediaDetails? _details;
  bool _loadingDetails = false;
  bool _isFinished = false;
  int _currentPosition = 0;
  bool _loadingWatched = false;
  bool _loadingProgress = false;

  @override
  void initState() {
    super.initState();
    _media = widget.movieItem?.media ?? widget.movie!;
    _isFinished = widget.movieItem?.isFinished ?? false;
    _currentPosition = widget.movieItem?.currentPositionSeconds ?? 0;
    // Paint from the shared cache before the first frame when this film has
    // been opened before this session — the page then opens complete instead
    // of on a bare backdrop with "Chargement des informations…".
    _adopt(MediaDetailsCache.peek(_media.id));
    _loadDetails();
    if (widget.movieItem == null) {
      _loadProgress();
    }
  }

  /// Folds a details payload into the page state, enriching the local handle
  /// with the catalog's title/overview/poster.
  void _adopt(MediaDetails? details) {
    if (details == null) return;
    _details = details;
    _media = Media(
      id: _media.id,
      type: _media.type,
      title: details.title.isNotEmpty ? details.title : _media.title,
      filePath: _media.filePath,
      duration: _media.duration,
      parentId: _media.parentId,
      posterUrl: details.posterUrl ?? _media.posterUrl,
      overview: details.overview ?? _media.overview,
      releaseDate: details.releaseDate ?? _media.releaseDate,
      tmdbId: details.tmdbId ?? _media.tmdbId,
      seasonNumber: _media.seasonNumber,
      episodeNumber: _media.episodeNumber,
      createdAt: _media.createdAt,
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
        _media.id,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() => _adopt(details));
    } catch (_) {
      // Keep local data on failure (offline / no TMDB key).
    } finally {
      if (mounted && _loadingDetails) setState(() => _loadingDetails = false);
    }
  }

  Future<void> _loadProgress() async {
    setState(() => _loadingProgress = true);
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final data = await api.getProgress(_media.id);
      if (!mounted) return;
      setState(() {
        _isFinished = data['is_finished'] as bool? ?? false;
        _currentPosition = data['current_position_seconds'] as int? ?? 0;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingProgress = false);
    }
  }

  Future<void> _toggleWatched() async {
    setState(() => _loadingWatched = true);
    try {
      final library = Provider.of<LibraryProvider>(context, listen: false);
      final home = Provider.of<HomeProvider>(context, listen: false);
      final watched = await library.setMediaWatched(_media.id, !_isFinished);
      await home.loadHome(silent: true);
      if (!mounted) return;
      setState(() {
        _isFinished = watched;
        if (watched && _media.duration > 0) {
          _currentPosition = _media.duration;
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible de mettre à jour le statut')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingWatched = false);
    }
  }

  double? get _progress {
    final duration = _media.duration;
    if (duration <= 0 || _isFinished) return null;
    if (_currentPosition <= 0) return null;
    return (_currentPosition / duration).clamp(0.0, 1.0);
  }

  bool get _hasProgress => !_isFinished && _currentPosition > 0;

  Future<void> _rematch() async {
    final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
    final fileName = _details?.fileName ??
        (_media.filePath != null && _media.filePath!.isNotEmpty
            ? _media.filePath!.split(RegExp(r'[\\/]+')).last
            : null);

    final choice = await MetadataFixSheet.show(
      context,
      api: api,
      initialQuery: _media.title,
      type: MediaType.movie,
      fileName: fileName,
    );

    if (choice == null || !mounted) return;

    final home = Provider.of<HomeProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated =
          await api.rematchMediaMetadata(_media.id, tmdbId: choice.tmdbId);
      if (!mounted) return;
      // The cached payload now describes the wrong title — drop it everywhere,
      // not just on this page, or the player would still show the old logo.
      MediaDetailsCache.invalidate(_media.id);
      setState(() {
        _media = updated;
        _details = null;
      });
      await _loadDetails(forceRefresh: true);
      await home.loadHome(silent: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Fiche mise à jour')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Impossible de mettre à jour la fiche')),
      );
    }
  }

  /// Le film tel que le lecteur et le téléchargement le voient, progression
  /// locale comprise. Un seul point de construction, pour que les deux boutons
  /// ne divergent pas.
  HomeMediaItem get _playbackItem =>
      widget.movieItem ??
      HomeMediaItem(
        media: _media,
        currentPositionSeconds: _currentPosition,
        duration: _media.duration,
        isFinished: _isFinished,
      );

  void _play() {
    final item = _playbackItem;
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
        builder: (_) => PlayerScreen(media: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metadata = buildMetadataChips(
      type: MediaType.movie,
      releaseDate: _details?.releaseDate ?? _media.releaseDate,
      runtimeMinutes: _details?.runtime ?? 0,
      durationSeconds: _media.duration,
      rating: _details?.voteAverage ?? 0,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: DetailBackdropHeader(
              fallback: _media,
              details: _details,
              metadata: metadata,
              onBack: () => Navigator.of(context).pop(),
              actions: Row(
                children: [
                  ElevatedButton.icon(
                    // The remote lands on Play: on a detail screen opened from
                    // a couch there is exactly one thing anyone came for.
                    autofocus: TvMode.isTv,
                    onPressed: _play,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_hasProgress ? 'REPRENDRE' : 'LECTURE'),
                  ),
                  const SizedBox(width: 12),
                  WatchedActionButton(
                    isWatched: _isFinished,
                    isLoading: _loadingWatched || _loadingProgress,
                    onPressed: _toggleWatched,
                  ),
                  const SizedBox(width: 4),
                  MediaDownloadButton(item: _playbackItem),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _rematch,
                    tooltip: 'Corriger la fiche',
                    icon: const Icon(Icons.edit_note_rounded),
                    color: AppColors.textSecondary,
                  ),
                  if (_hasProgress && _progress != null) ...[
                    const SizedBox(width: 16),
                    Text(
                      '${(_progress! * 100).round()}% visionné',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: DetailInfoSection(
              details: _details,
              fallbackOverview: _media.overview,
              emptyOverviewLabel: _loadingDetails
                  ? 'Chargement des informations…'
                  : 'Synopsis indisponible pour ce film.',
            ),
          ),
          if (_details?.collection != null)
            SliverToBoxAdapter(
              child: CollectionSection(
                collection: _details!.collection!,
                onTap: () => openCollection(context, _details!.collection!),
              ),
            ),
          if (_details?.cast.isNotEmpty ?? false)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: CastSection(
                  cast: _details!.cast,
                  onTapMember: (member) => openPerson(context, member.tmdbId, name: member.name),
                ),
              ),
            ),
          if (_details?.similarTitles.isNotEmpty ?? false)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 32),
                child: SimilarTitlesSection(
                  items: _details!.similarTitles,
                  onTapItem: (item) => openCatalogItem(context, item),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
