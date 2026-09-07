import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../providers/library_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/media_card.dart';
import 'movie_detail_screen.dart';
import 'show_detail_screen.dart';

/// Full-page grid of every catalog result for a query, opened when the user
/// presses Enter in the global search bar.
class SearchResultsScreen extends StatelessWidget {
  final String query;

  const SearchResultsScreen({super.key, required this.query});

  void _openMedia(BuildContext context, Media media, LibraryProvider lp) {
    if (media.type == MediaType.movie) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MovieDetailScreen(
            movie: media,
            movieItem: lp.movieItemFor(media.id),
          ),
        ),
      );
      return;
    }
    if (media.type == MediaType.show) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ShowDetailScreen(show: media)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lp = context.watch<LibraryProvider>();
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width >= 900 ? 48.0 : 16.0;
    final results = lp.searchCatalog(query);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          'Résultats pour « $query »',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: results.isEmpty
          ? EmptyStateView(
              icon: Icons.search_off_rounded,
              title: 'Aucun résultat',
              message: 'Aucun film ou série ne correspond à « $query ».',
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 8, horizontalPadding, 0),
                    child: Text(
                      '${results.length} résultat${results.length > 1 ? 's' : ''}',
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                      horizontalPadding, 20, horizontalPadding, 48),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) => SliverGrid(
                      gridDelegate: AppLayout.posterGridDelegate(
                        constraints.crossAxisExtent,
                        compact: AppLayout.isCompact(context),
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final media = results[index];
                          return MediaCard(
                            media: media,
                            progress: media.type == MediaType.movie
                                ? lp.movieProgressFor(media.id)
                                : null,
                            onTap: () => _openMedia(context, media, lp),
                          );
                        },
                        childCount: results.length,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
