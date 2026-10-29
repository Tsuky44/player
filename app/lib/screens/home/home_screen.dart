import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../tv/tv_mode.dart';
import '../../utils/hero_slides.dart';
import '../../utils/on_screen.dart';
import '../../navigation/search_route_observer.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/interface_tour/tour_anchor.dart';
import '../../widgets/global/hero_carousel.dart';
import '../../widgets/global/live_progress_state.dart';
import '../../widgets/global/media_row.dart';
import '../../widgets/global/poster_launch_route.dart';
import '../../widgets/global/remote_playback_banner.dart';
import '../../widgets/global/skeleton.dart';
import '../../widgets/global/hero_banner.dart' show HeroBanner;
import '../library/movie_detail_screen.dart';
import '../library/show_detail_screen.dart';
import '../player/player_screen.dart';
import 'home_empty_view.dart';
import 'home_recent_rows.dart';
import '../../l10n/tr.dart';

class HomeScreen extends StatefulWidget {
  final bool embedded;
  final VoidCallback? onNavigateToMovies;
  final VoidCallback? onNavigateToShows;

  /// « Tout voir » d'une rangée de bibliothèque : ouvre son onglet.
  final void Function(int libraryId)? onOpenLibrary;

  const HomeScreen({
    super.key,
    this.embedded = false,
    this.onNavigateToMovies,
    this.onNavigateToShows,
    this.onOpenLibrary,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with OnScreenState, LiveProgressState {
  HomeProvider? _homeProvider;
  final _scrollController = ScrollController();

  /// L'accueil n'était chargé qu'à l'ouverture de l'app : un téléphone sorti
  /// de veille gardait la rangée « Reprendre la lecture » d'avant, pendant que
  /// la série avançait sur un autre appareil. Il se relit à chaque retour à
  /// l'écran, et pendant qu'il reste affiché dès que la série avance ailleurs.
  /// Le tout premier chargement est celui d'`initState`.
  @override
  void onProgressChanged() => _homeProvider?.loadHome(silent: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeProvider = Provider.of<HomeProvider>(context, listen: false);
      _homeProvider!.addListener(_onHomeProviderChanged);
      _homeProvider!.loadHome();
      Provider.of<LibraryProvider>(context, listen: false)
          .ensureCatalogLoaded();
    });
  }

  @override
  void dispose() {
    _homeProvider?.removeListener(_onHomeProviderChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onHomeProviderChanged() {
    if (!mounted || _homeProvider == null) return;
    final msg = _homeProvider!.consumeCompletionMessage();
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
      if (msg.startsWith('Re-détection') || msg.startsWith('Scan')) {
        final library = Provider.of<LibraryProvider>(context, listen: false);
        library.loadShows();
        library.loadMovies();
        // Une analyse suit souvent une bibliothèque ajoutée ou déplacée.
        library.loadLibraries();
        library.reloadOpenLibraries();
      }
    }
  }

  void _openMedia(BuildContext context, Media media) {
    if (media.type == MediaType.movie) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MovieDetailScreen(movie: media)),
      );
    } else if (media.type == MediaType.show) {
      final library = Provider.of<LibraryProvider>(context, listen: false);
      final resolved = library.resolveCanonicalShow(media);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ShowDetailScreen(show: resolved)),
      );
    }
  }

  void _openContinueWatchingDetails(
    BuildContext context,
    HomeMediaItem item, {
    LaunchOrigin? origin,
  }) {
    final target = item.detailMedia;
    if (target == null) return;

    if (target.type == MediaType.movie) {
      pushPosterLaunch(
        Navigator.of(context),
        origin: origin,
        destination: LaunchDestination.details,
        builder: (_) => MovieDetailScreen(
          movieItem: item,
          movie: target,
        ),
      );
      return;
    }

    if (target.type == MediaType.show) {
      final library = Provider.of<LibraryProvider>(context, listen: false);
      final resolved = library.resolveCanonicalShow(target);
      pushPosterLaunch(
        Navigator.of(context),
        origin: origin,
        destination: LaunchDestination.details,
        builder: (_) => ShowDetailScreen(show: resolved),
      );
    }
  }

  Future<void> _playMedia(
    BuildContext context,
    dynamic media, {
    LaunchOrigin? origin,
  }) async {
    await pushPosterLaunch(
      Navigator.of(context, rootNavigator: true),
      origin: origin,
      destination: LaunchDestination.player,
      settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
      builder: (_) => PlayerScreen(media: media),
    );
    if (!context.mounted) return;
    Provider.of<HomeProvider>(context, listen: false).loadHome(silent: true);
  }

  void _onHeroPlay(BuildContext context, HeroSlide slide) {
    if (slide.continueItem != null) {
      _playMedia(context, slide.continueItem);
      return;
    }
    if (slide.media.type == MediaType.movie) {
      _playMedia(context, slide.media);
    } else if (slide.media.type == MediaType.show) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ShowDetailScreen(show: slide.media)),
      );
    }
  }

  void _onHeroInfo(BuildContext context, HeroSlide slide) {
    _openMedia(context, slide.media);
  }

  @override
  Widget build(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    // Barre d'état + la barre du haut du téléphone (voir [MobileTopBar]).
    final topBarHeight = MediaQuery.paddingOf(context).top + 56;
    final isTv = TvScope.of(context);
    final data = homeProvider.homeData;
    final discovery = data == null
        ? const <Media>[]
        : _interleave(data.discoveryMovies, data.discoveryShows);
    final heroSlides = data != null
        ? buildHeroSlides(
            data,
            serverBaseUrl: authProvider.apiClient.baseUrl,
            userId: authProvider.currentUser?.id ?? 0,
          )
        : <HeroSlide>[];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: homeProvider.isLoading
          ? HomeSkeleton(
              heroHeight: HeroBanner.heightFor(context),
              topInset: widget.embedded ? 0 : topBarHeight,
            )
          : homeProvider.errorMessage != null
              ? ErrorStateView(
                  message: homeProvider.errorMessage!,
                  onRetry: () => homeProvider.loadHome(),
                )
              : Stack(
                  children: [
                    RefreshIndicator(
                      onRefresh: () => homeProvider.loadHome(),
                      color: AppColors.primary,
                      edgeOffset: widget.embedded ? 0 : topBarHeight,
                      child: CustomScrollView(
                        scrollCacheExtent: AppLayout.imageCacheExtent(context),
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          // Le carrousel commence sous la barre du haut, pas
                          // derrière elle : elle y était transparente et
                          // posée sur l'affiche.
                          if (!widget.embedded)
                            SliverToBoxAdapter(
                              child: SizedBox(height: topBarHeight),
                            ),
                          if (heroSlides.isNotEmpty)
                            SliverToBoxAdapter(
                              child: HeroCarousel(
                                slides: heroSlides,
                                onPlay: (slide) => _onHeroPlay(context, slide),
                                onInfo: (slide) => _onHeroInfo(context, slide),
                                // On a television the banner is where the
                                // remote starts. See below for why it is not
                                // the first row.
                                autofocusPlay: isTv,
                              ),
                            )
                          else
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: widget.embedded ? 120 : 200,
                                child: Center(
                                  child: Text(
                                    tr('Bienvenue sur Onyx'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall,
                                  ),
                                ),
                              ),
                            ),
                          if (data != null &&
                              data.continueWatching.isEmpty &&
                              data.recentMovies.isEmpty &&
                              data.recentShows.isEmpty)
                            SliverFillRemaining(
                              child: Consumer<LibraryProvider>(
                                builder: (context, library, _) =>
                                    HomeEmptyView(
                                  libraries: library.librariesLoaded
                                      ? library.libraries
                                      : null,
                                  permissions: authProvider.permissions,
                                  homeProvider: homeProvider,
                                ),
                              ),
                            )
                          else ...[
                            const SliverToBoxAdapter(
                                child: SizedBox(height: 8)),
                            if (data != null &&
                                data.continueWatching.isNotEmpty)
                              SliverToBoxAdapter(
                                child: TourTarget(
                                  anchor: TourAnchor.resume,
                                  child: MediaRow(
                                    title: tr('Reprendre la lecture'),
                                    items: data.continueWatching,
                                    isContinueWatching: true,
                                    // Never on a television, where taking the
                                    // focus also scrolls this row to the middle
                                    // of the screen — the banner the user has
                                    // not seen yet goes off the top, and the home
                                    // screen opens on a poster. The banner's play
                                    // button holds the focus there instead.
                                    autofocusFirstItem: !isTv,
                                    onItemTap: (item) =>
                                        _playMedia(context, item),
                                    onContinueWatchingPlay: (item, origin) =>
                                        _playMedia(context, item, origin: origin),
                                    onContinueWatchingTitleTap: (item, origin) =>
                                        _openContinueWatchingDetails(
                                      context,
                                      item,
                                      origin: origin,
                                    ),
                                    onContinueWatchingMarkWatched: (item) =>
                                        homeProvider
                                            .markContinueWatchingAsWatched(item),
                                    onContinueWatchingRemove: (item) =>
                                        homeProvider
                                            .hideContinueWatchingItem(item),
                                  ),
                                ),
                              ),
                            if (data != null)
                              ...homeRecentSlivers(
                                data: data,
                                isTv: isTv,
                                onOpenLibrary: widget.onOpenLibrary,
                                onSeeAllMovies: widget.onNavigateToMovies,
                                onSeeAllShows: widget.onNavigateToShows,
                                onOpenMedia: (media) =>
                                    _openMedia(context, media),
                              ),
                            if (data != null && discovery.isNotEmpty) ...[
                              const SliverToBoxAdapter(
                                  child: SizedBox(height: 32)),
                              // Le serveur tire ces titres au hasard dans la
                              // bibliothèque pour des rangées « découverte »
                              // que l'accueil n'affichait pas : seul le bandeau
                              // en piochait quelques-uns. Sans elle, l'accueil
                              // ne changeait qu'à l'ajout d'un fichier.
                              SliverToBoxAdapter(
                                child: MediaRow(
                                  title: tr('À découvrir'),
                                  items: discovery,
                                  onItemTap: (item) =>
                                      _openMedia(context, item as Media),
                                ),
                              ),
                            ],
                            const SliverToBoxAdapter(
                                child: SizedBox(height: 48)),
                          ],
                        ],
                      ),
                    ),
                    const Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: SafeArea(
                        top: false,
                        child: Center(child: RemotePlaybackBanner()),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// Films et séries en alternance, pour qu'une rangée ne soit pas faite de
/// vingt films puis de vingt séries.
List<Media> _interleave(List<Media> movies, List<Media> shows) {
  final merged = <Media>[];
  final length = movies.length > shows.length ? movies.length : shows.length;
  for (var i = 0; i < length; i++) {
    if (i < movies.length) merged.add(movies[i]);
    if (i < shows.length) merged.add(shows[i]);
  }
  return merged;
}
