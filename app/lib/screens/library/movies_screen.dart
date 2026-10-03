import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../desktop_window.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import 'widgets/catalog_header.dart';
import '../../widgets/global/empty_state.dart';
import '../../utils/search_match.dart';
import '../../widgets/global/media_card.dart';
import '../../widgets/global/skeleton.dart';
import 'movie_detail_screen.dart';
import '../../theme/app_icons.dart';

enum _SortOption { title, recent, progress }

const Map<_SortOption, String> _sortLabels = {
  _SortOption.recent: 'Récents',
  _SortOption.title: 'A → Z',
  _SortOption.progress: 'En cours',
};

class MoviesScreen extends StatefulWidget {
  final bool embedded;

  const MoviesScreen({super.key, this.embedded = false});

  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  _SortOption _sort = _SortOption.recent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LibraryProvider>(context, listen: false).loadMovies();
    });
  }

  List<dynamic> _filteredMovies(LibraryProvider lp) {
    var items = List.of(lp.movies);
    switch (_sort) {
      case _SortOption.title:
        items.sort((a, b) =>
            titleSortKey(a.media.title).compareTo(titleSortKey(b.media.title)));
      case _SortOption.recent:
        items.sort((a, b) => b.media.createdAt.compareTo(a.media.createdAt));
      case _SortOption.progress:
        items.sort((a, b) {
          final aProg = a.isFinished ? -1.0 : a.percentWatched;
          final bProg = b.isFinished ? -1.0 : b.percentWatched;
          return bProg.compareTo(aProg);
        });
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final lp = Provider.of<LibraryProvider>(context);
    final horizontalPadding = AppLayout.pagePadding(context);
    final filtered = _filteredMovies(lp);
    final compact = AppLayout.isCompact(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: lp.errorMessage != null
          ? ErrorStateView(
              message: lp.errorMessage!,
              onRetry: () => lp.loadMovies(),
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      widget.embedded
                          ? embeddedShellContentTopInset(context)
                          : (compact
                              ? MediaQuery.paddingOf(context).top + 56
                              : 48),
                      horizontalPadding,
                      0,
                    ),
                    child: CatalogHeader<_SortOption>(
                      title: 'Films',
                      countLabel: lp.isLoadingMovies
                          ? null
                          : '${filtered.length} film${filtered.length > 1 ? 's' : ''}',
                      sortOptions: _sortLabels,
                      sort: _sort,
                      onSortChanged: (v) => setState(() => _sort = v),
                      compact: compact,
                    ),
                  ),
                ),
                if (lp.isLoadingMovies)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 24, horizontalPadding, 48),
                    sliver: const PosterGridSkeleton(),
                  )
                else if (lp.movies.isEmpty)
                  const SliverFillRemaining(
                    child: EmptyStateView(
                      icon: AppIcons.movie,
                      title: 'Aucun film',
                      message:
                          'Ajoutez des fichiers vidéo dans votre dossier Films puis synchronisez la bibliothèque.',
                    ),
                  )
                else if (filtered.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Text(
                        'Aucun film trouvé',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      24,
                      horizontalPadding,
                      MediaQuery.paddingOf(context).bottom + 48,
                    ),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) => SliverGrid(
                        gridDelegate: AppLayout.posterGridDelegate(
                          constraints.crossAxisExtent,
                          compact: compact,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final item = filtered[index];
                            return MediaCard(
                              media: item.media,
                              watched: item.isFinished,
                              progress:
                                  item.isFinished ? null : item.percentWatched,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        MovieDetailScreen(movieItem: item),
                                  ),
                                );
                              },
                            );
                          },
                          childCount: filtered.length,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
