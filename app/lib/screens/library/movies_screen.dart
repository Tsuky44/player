import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../desktop_window.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/media_card.dart';
import 'movie_detail_screen.dart';

enum _SortOption { title, recent, progress }

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
        items.sort((a, b) => a.media.title.compareTo(b.media.title));
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
      body: lp.isLoadingMovies
          ? const LoadingView()
          : lp.errorMessage != null
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Films',
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    fontSize: compact ? 26 : 32,
                                  ),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                const Spacer(),
                                _SortDropdown(
                                  value: _sort,
                                  onChanged: (v) => setState(() => _sort = v),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${filtered.length} film${filtered.length > 1 ? 's' : ''}',
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (lp.movies.isEmpty)
                      SliverFillRemaining(
                        child: EmptyStateView(
                          icon: Icons.movie_creation_outlined,
                          title: 'Aucun film',
                          message:
                              'Ajoutez des fichiers vidéo dans votre dossier Films puis synchronisez la bibliothèque.',
                        ),
                      )
                    else if (filtered.isEmpty)
                      SliverFillRemaining(
                        child: Center(
                          child: Text(
                            'Aucun film trouvé',
                            style: const TextStyle(color: AppColors.textMuted),
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
                                  progress: item.isFinished
                                      ? null
                                      : item.percentWatched,
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

class _SortDropdown extends StatelessWidget {
  final _SortOption value;
  final ValueChanged<_SortOption> onChanged;

  const _SortDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_SortOption>(
          value: value,
          dropdownColor: AppColors.surfaceElevated,
          icon: const Icon(Icons.sort_rounded,
              color: AppColors.textSecondary, size: 20),
          items: const [
            DropdownMenuItem(value: _SortOption.recent, child: Text('Récents')),
            DropdownMenuItem(value: _SortOption.title, child: Text('A → Z')),
            DropdownMenuItem(
                value: _SortOption.progress, child: Text('En cours')),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
