import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../desktop_window.dart';
import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../utils/responsive.dart';
import '../../utils/search_match.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/media_card.dart';
import '../../widgets/global/poster_grid_zoom_region.dart';
import '../../widgets/global/skeleton.dart';
import '../shell/shell_tabs.dart';
import 'widgets/catalog_header.dart';

enum _SortOption { recent, title, progress }

const Map<_SortOption, String> _sortLabels = {
  _SortOption.recent: 'Récents',
  _SortOption.title: 'A → Z',
  _SortOption.progress: 'En cours',
};

/// Une affiche de la grille : un film avec sa progression, ou une série.
typedef _Entry = ({Media media, HomeMediaItem? movie});

/// L'icône d'une bibliothèque, d'après ce qu'elle contient. [selected] rend la
/// variante pleine, celle d'un onglet actif.
IconData libraryIcon(LibraryKind kind, {bool selected = false}) =>
    switch (kind) {
      LibraryKind.movies => selected ? AppIcons.movieSelected : AppIcons.movie,
      LibraryKind.shows => selected ? AppIcons.seriesSelected : AppIcons.series,
      // Pas de variante pleine dans le jeu d'icônes : l'onglet actif se lit à
      // sa couleur et à la graisse de son nom.
      LibraryKind.other => AppIcons.folder,
    };

/// Le catalogue d'une bibliothèque du serveur, sous le nom que son
/// administrateur lui a donné (ADR-0058).
///
/// Un seul écran pour toutes : ce qui change d'une bibliothèque à l'autre est
/// son nom et la fiche qu'ouvre une affiche, pas la grille.
class LibraryScreen extends StatefulWidget {
  final MediaLibrary library;
  final bool embedded;

  const LibraryScreen(
      {super.key, required this.library, this.embedded = false});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  _SortOption _sort = _SortOption.recent;
  bool _loadScheduled = false;

  bool get _isShows => widget.library.kind == LibraryKind.shows;

  /// Charge le catalogue s'il manque : à l'ouverture, et de nouveau quand un
  /// changement de serveur l'a vidé sous un onglet resté monté.
  void _loadIfMissing(LibraryProvider lp) {
    final library = widget.library;
    if (_loadScheduled ||
        lp.hasLoadedLibrary(library) ||
        lp.isLoadingLibrary(library) ||
        lp.libraryError(library) != null) {
      return;
    }
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (mounted) lp.loadLibrary(widget.library);
    });
  }

  List<_Entry> _entries(LibraryProvider lp) {
    final List<_Entry> entries = _isShows
        ? [
            for (final show in lp.showsOf(widget.library))
              (media: show, movie: null)
          ]
        : [
            for (final item in lp.moviesOf(widget.library))
              (media: item.media, movie: item),
          ];
    switch (_sort) {
      case _SortOption.title:
        entries.sort((a, b) =>
            titleSortKey(a.media.title).compareTo(titleSortKey(b.media.title)));
      case _SortOption.recent:
        entries.sort((a, b) => b.media.createdAt.compareTo(a.media.createdAt));
      case _SortOption.progress:
        double progress(_Entry entry) {
          final movie = entry.movie;
          if (movie == null) return 0;
          return movie.isFinished ? -1.0 : movie.percentWatched;
        }
        entries.sort((a, b) => progress(b).compareTo(progress(a)));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final lp = Provider.of<LibraryProvider>(context);
    final library = widget.library;
    _loadIfMissing(lp);

    final horizontalPadding = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final error = lp.libraryError(library);
    // Rien de reçu encore se lit comme un chargement, pas comme « vide ».
    final loading =
        lp.isLoadingLibrary(library) || !lp.hasLoadedLibrary(library);
    final entries = _entries(lp);
    final count = entries.length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: error != null
          ? ErrorStateView(
              message: error,
              onRetry: () => lp.loadLibrary(library),
            )
          : PosterGridZoomRegion(
              child: CustomScrollView(
                scrollCacheExtent: AppLayout.imageCacheExtent(context),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        shellTabTopInset(context, embedded: widget.embedded),
                        horizontalPadding,
                        0,
                      ),
                      child: CatalogHeader<_SortOption>(
                        title: ShellTabs.label(library),
                        countLabel: loading
                            ? null
                            : tr('{0} titre{1}', [count, count > 1 ? 's' : '']),
                        sortOptions: {
                          for (final option in _sortLabels.entries)
                            // Une série n'a pas de position de lecture à elle.
                            if (!_isShows || option.key != _SortOption.progress)
                              option.key: option.value,
                        },
                        sort: _sort,
                        onSortChanged: (v) => setState(() => _sort = v),
                        compact: compact,
                      ),
                    ),
                  ),
                  if (loading)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                          horizontalPadding, 24, horizontalPadding, 48),
                      sliver: const PosterGridSkeleton(),
                    )
                  else if (entries.isEmpty)
                    SliverFillRemaining(
                      child: EmptyStateView(
                        icon: libraryIcon(library.kind),
                        title: tr('Bibliothèque vide'),
                        message: tr('Les fichiers ajoutés au dossier de cette '
                            'bibliothèque apparaissent ici d’eux-mêmes.'),
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
                            context,
                            constraints.crossAxisExtent,
                            compact: compact,
                            withMeta: false,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final entry = entries[index];
                              final movie = entry.movie;
                              return MediaCard(
                                media: entry.media,
                                item: movie,
                                watched: movie?.isFinished ?? false,
                                progress: movie == null || movie.isFinished
                                    ? null
                                    : movie.percentWatched,
                              );
                            },
                            childCount: entries.length,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
