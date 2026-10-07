import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../desktop_window.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import 'widgets/catalog_header.dart';
import '../../widgets/global/empty_state.dart';
import '../../utils/search_match.dart';
import '../../widgets/global/media_card.dart';
import '../../widgets/global/skeleton.dart';
import 'show_detail_screen.dart';
import '../../theme/app_icons.dart';
import '../../l10n/tr.dart';

enum _SortOption { title, recent }

const Map<_SortOption, String> _sortLabels = {
  _SortOption.recent: 'Récents',
  _SortOption.title: 'A → Z',
};

class ShowsScreen extends StatefulWidget {
  final bool embedded;

  const ShowsScreen({super.key, this.embedded = false});

  @override
  State<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends State<ShowsScreen> {
  _SortOption _sort = _SortOption.recent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LibraryProvider>(context, listen: false).loadShows();
    });
  }

  List<Media> _filteredShows(LibraryProvider lp) {
    var items = List.of(lp.shows);
    switch (_sort) {
      case _SortOption.title:
        items.sort(
            (a, b) => titleSortKey(a.title).compareTo(titleSortKey(b.title)));
      case _SortOption.recent:
        items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final lp = Provider.of<LibraryProvider>(context);
    final horizontalPadding = AppLayout.pagePadding(context);
    final filtered = _filteredShows(lp);
    final compact = AppLayout.isCompact(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: lp.errorMessage != null
          ? ErrorStateView(
              message: lp.errorMessage!,
              onRetry: () => lp.loadShows(),
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
                      title: tr('Séries'),
                      countLabel: lp.isLoadingShows
                          ? null
                          : tr('{0} série{1}', [filtered.length, filtered.length > 1 ? 's' : '']),
                      sortOptions: _sortLabels,
                      sort: _sort,
                      onSortChanged: (v) => setState(() => _sort = v),
                      compact: compact,
                    ),
                  ),
                ),
                if (lp.isLoadingShows)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 24, horizontalPadding, 48),
                    sliver: const PosterGridSkeleton(),
                  )
                else if (lp.shows.isEmpty)
                  SliverFillRemaining(
                    child: EmptyStateView(
                      icon: AppIcons.series,
                      title: tr('Aucune série'),
                      message:
                          tr('Ajoutez des dossiers de séries avec des '
                              'épisodes SxxExx puis synchronisez la '
                              'bibliothèque.'),
                    ),
                  )
                else if (filtered.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Text(
                        tr('Aucune série trouvée'),
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
                            final show = filtered[index];
                            return MediaCard(
                              media: show,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        ShowDetailScreen(show: show),
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
