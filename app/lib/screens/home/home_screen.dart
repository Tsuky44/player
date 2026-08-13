import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/hero_slides.dart';
import '../../navigation/search_route_observer.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/hero_carousel.dart';
import '../../widgets/global/media_row.dart';
import '../../widgets/global/sticky_glass_search.dart';
import '../library/movie_detail_screen.dart';
import '../library/show_detail_screen.dart';
import '../player/player_screen.dart';

class HomeScreen extends StatefulWidget {
  final bool embedded;
  final VoidCallback? onNavigateToMovies;
  final VoidCallback? onNavigateToShows;

  const HomeScreen({
    super.key,
    this.embedded = false,
    this.onNavigateToMovies,
    this.onNavigateToShows,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HomeProvider? _homeProvider;
  final _scrollController = ScrollController();
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      setState(() => _scrollOffset = _scrollController.offset);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeProvider = Provider.of<HomeProvider>(context, listen: false);
      _homeProvider!.addListener(_onHomeProviderChanged);
      _homeProvider!.loadHome();
      Provider.of<LibraryProvider>(context, listen: false).ensureCatalogLoaded();
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

  void _openContinueWatchingDetails(BuildContext context, HomeMediaItem item) {
    final target = item.detailMedia;
    if (target == null) return;

    if (target.type == MediaType.movie) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MovieDetailScreen(
            movieItem: item,
            movie: target,
          ),
        ),
      );
      return;
    }

    if (target.type == MediaType.show) {
      final library = Provider.of<LibraryProvider>(context, listen: false);
      final resolved = library.resolveCanonicalShow(target);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ShowDetailScreen(show: resolved)),
      );
    }
  }

  void _playMedia(BuildContext context, dynamic media) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
        builder: (_) => PlayerScreen(media: media),
      ),
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
    final data = homeProvider.homeData;
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
          ? const LoadingView()
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
                      edgeOffset: widget.embedded ? 0 : 56,
                      child: CustomScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          if (!widget.embedded)
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 56),
                            ),
                          if (heroSlides.isNotEmpty)
                            SliverToBoxAdapter(
                              child: HeroCarousel(
                                slides: heroSlides,
                                onPlay: (slide) => _onHeroPlay(context, slide),
                                onInfo: (slide) => _onHeroInfo(context, slide),
                              ),
                            )
                          else
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: widget.embedded ? 120 : 200,
                                child: Center(
                                  child: Text(
                                    'Bienvenue sur Onyx',
                                    style: Theme.of(context).textTheme.headlineSmall,
                                  ),
                                ),
                              ),
                            ),

                          if (data != null &&
                              data.continueWatching.isEmpty &&
                              data.recentMovies.isEmpty &&
                              data.recentShows.isEmpty)
                            SliverFillRemaining(
                              child: EmptyStateView(
                                icon: Icons.movie_filter_outlined,
                                title: 'Bibliothèque vide',
                                message:
                                    'Ajoutez des fichiers dans vos dossiers Films et Séries, puis synchronisez depuis le menu profil.',
                                actionLabel: 'Synchroniser',
                                onAction: () => homeProvider.triggerLibraryScan(),
                                secondaryActionLabel: 'Extraire les sous-titres',
                                onSecondaryAction: () => homeProvider.triggerSubtitleExtract(),
                              ),
                            )
                          else ...[
                            const SliverToBoxAdapter(child: SizedBox(height: 8)),
                            if (data != null && data.continueWatching.isNotEmpty)
                              SliverToBoxAdapter(
                                child: MediaRow(
                                  title: 'Reprendre la lecture',
                                  items: data.continueWatching,
                                  isContinueWatching: true,
                                  onItemTap: (item) => _playMedia(context, item),
                                  onContinueWatchingTitleTap: (item) =>
                                      _openContinueWatchingDetails(context, item),
                                  onContinueWatchingMarkWatched: (item) =>
                                      homeProvider.markContinueWatchingAsWatched(item),
                                  onContinueWatchingRemove: (item) =>
                                      homeProvider.hideContinueWatchingItem(item),
                                ),
                              ),
                            if (data != null && data.recentMovies.isNotEmpty) ...[
                              const SliverToBoxAdapter(child: SizedBox(height: 32)),
                              SliverToBoxAdapter(
                                child: MediaRow(
                                  title: 'Films récents',
                                  items: data.recentMovies,
                                  onSeeAll: widget.onNavigateToMovies,
                                  onItemTap: (item) => _openMedia(context, item as Media),
                                ),
                              ),
                            ],
                            if (data != null && data.recentShows.isNotEmpty) ...[
                              const SliverToBoxAdapter(child: SizedBox(height: 32)),
                              SliverToBoxAdapter(
                                child: MediaRow(
                                  title: 'Séries récentes',
                                  items: data.recentShows,
                                  onSeeAll: widget.onNavigateToShows,
                                  onItemTap: (item) => _openMedia(context, item as Media),
                                ),
                              ),
                            ],
                            const SliverToBoxAdapter(child: SizedBox(height: 48)),
                          ],
                        ],
                      ),
                    ),

                    if (!widget.embedded)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _HomeOverlayBar(
                          scrollOffset: _scrollOffset,
                          homeProvider: homeProvider,
                          authProvider: authProvider,
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _HomeOverlayBar extends StatelessWidget {
  final double scrollOffset;
  final HomeProvider homeProvider;
  final AuthProvider authProvider;

  const _HomeOverlayBar({
    required this.scrollOffset,
    required this.homeProvider,
    required this.authProvider,
  });

  @override
  Widget build(BuildContext context) {
    final opaque = scrollOffset > 80;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: opaque ? AppColors.background : Colors.black.withValues(alpha: 0.35),
        boxShadow: opaque
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 12)]
            : null,
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
          child: Row(
            children: [
              const GlassBrand(),
              const SizedBox(width: 10),
              const Expanded(child: InlineCatalogSearch()),
              const SizedBox(width: 8),
              if (homeProvider.isScanning ||
                  homeProvider.isBackfillingMetadata ||
                  homeProvider.isRedetectingAll ||
                  homeProvider.isExtractingSubtitles)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              const AppDownloadButton(),
              AccountMenu(authProvider: authProvider),
            ],
          ),
        ),
      ),
    );
  }
}
