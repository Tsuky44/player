import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/search_provider.dart';
import '../../screens/library/movie_detail_screen.dart';
import '../../screens/library/search_results_screen.dart';
import '../../screens/library/show_detail_screen.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import 'glass_chrome.dart';

/// Max number of results shown inline in the dropdown before offering "see all".
const int _kInlineResultLimit = 8;

/// Styled catalog search with an inline results panel rendered in the root
/// [Overlay] so it is never clipped by the frosted header strip.
class GlassCatalogSearch extends StatefulWidget {
  final bool expandInline;
  final double collapsedWidth;
  final double expandedWidth;

  /// When true, the idle state is a circular search icon instead of a field.
  final bool compactTrigger;

  const GlassCatalogSearch({
    super.key,
    this.expandInline = true,
    this.collapsedWidth = 180,
    this.expandedWidth = 300,
    this.compactTrigger = false,
  });

  @override
  State<GlassCatalogSearch> createState() => _GlassCatalogSearchState();
}

class _GlassCatalogSearchState extends State<GlassCatalogSearch> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final LayerLink _link = LayerLink();
  final Object _tapGroupId = Object();
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LibraryProvider>().ensureCatalogLoaded();
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    context.read<SearchProvider>().setExpanded(_focusNode.hasFocus);
  }

  void _onQueryChanged(String value) {
    context.read<SearchProvider>().setQuery(value);
  }

  void _clear() {
    _controller.clear();
    context.read<SearchProvider>().clear();
    _focusNode.unfocus();
  }

  void _openResult(Media media) {
    final library = context.read<LibraryProvider>();
    _clear();

    if (media.type == MediaType.movie) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MovieDetailScreen(
            movie: media,
            movieItem: library.movieItemFor(media.id),
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

  void _showAllResults([String? explicitQuery]) {
    final query = (explicitQuery ?? _controller.text).trim();
    if (query.isEmpty) return;
    _clear();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchResultsScreen(query: query)),
    );
  }

  // --- Overlay lifecycle ---------------------------------------------------

  void _ensureOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _overlayEntry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final search = overlayContext.watch<SearchProvider>();
    final library = overlayContext.watch<LibraryProvider>();

    if (!search.isActive) return const SizedBox.shrink();

    final results = library.searchCatalog(search.query);
    final loading = library.isLoadingMovies || library.isLoadingShows;

    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topRight,
        child: TapRegion(
          groupId: _tapGroupId,
          onTapOutside: (_) => _clear(),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: widget.expandedWidth,
              child: GlassSurface(
                borderRadius: BorderRadius.circular(16),
                child: _SearchResultsPanel(
                  maxWidth: widget.expandedWidth,
                  results: results,
                  isLoading: loading,
                  query: search.query,
                  onTap: _openResult,
                  onSeeAll: () => _showAllResults(search.query),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<SearchProvider>();
    final expanded =
        widget.expandInline && (search.isExpanded || search.isActive);
    final showField = !widget.compactTrigger || expanded;
    final width = showField
        ? (expanded ? widget.expandedWidth : widget.collapsedWidth)
        : 40.0;

    // Keep the overlay entry alive; its builder decides what to render.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureOverlay();
    });

    if (widget.compactTrigger && !showField) {
      return GlassIconButton(
        size: 40,
        onTap: () {
          context.read<SearchProvider>().setExpanded(true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode.requestFocus();
          });
        },
        child: Icon(
          Icons.search_rounded,
          size: 20,
          color: AppColors.textPrimary.withValues(alpha: 0.92),
        ),
      );
    }

    return TapRegion(
      groupId: _tapGroupId,
      child: CompositedTransformTarget(
        link: _link,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: width,
          child: GlassSearchInput(
            controller: _controller,
            focusNode: _focusNode,
            onChanged: _onQueryChanged,
            onSubmitted: (_) => _showAllResults(),
            onClear: _clear,
            hint: expanded ? 'Titre, film, série…' : 'Rechercher',
            focused: _focusNode.hasFocus,
            hasText: _controller.text.isNotEmpty,
          ),
        ),
      ),
    );
  }
}

class _SearchResultsPanel extends StatelessWidget {
  final double maxWidth;
  final List<Media> results;
  final bool isLoading;
  final String query;
  final ValueChanged<Media> onTap;
  final VoidCallback onSeeAll;

  const _SearchResultsPanel({
    required this.maxWidth,
    required this.results,
    required this.isLoading,
    required this.query,
    required this.onTap,
    required this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return SizedBox(
        width: maxWidth,
        height: 112,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (results.isEmpty) {
      return SizedBox(
        width: maxWidth,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            'Aucun résultat pour « $query »',
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.95),
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    final auth = context.read<AuthProvider>();
    final baseUrl = auth.apiClient.baseUrl;
    final visibleCount = results.length.clamp(0, _kInlineResultLimit);
    final hasMore = results.length > _kInlineResultLimit;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 340),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: visibleCount,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              color: Colors.white.withValues(alpha: 0.06),
            ),
            itemBuilder: (context, index) {
              final media = results[index];
              final poster =
                  resolvePosterUrl(media.posterUrl, serverBaseUrl: baseUrl);
              final typeLabel = media.type == MediaType.movie ? 'Film' : 'Série';

              return InkWell(
                onTap: () => onTap(media),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: poster != null
                            ? Image.network(
                                poster,
                                width: 34,
                                height: 50,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _posterPlaceholder(),
                              )
                            : _posterPlaceholder(),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              media.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              typeLabel,
                              style: TextStyle(
                                color: AppColors.textMuted.withValues(alpha: 0.9),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        InkWell(
          onTap: onSeeAll,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  hasMore
                      ? 'Voir les ${results.length} résultats'
                      : 'Voir tous les résultats',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_rounded,
                    size: 15, color: AppColors.accent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _posterPlaceholder() {
    return Container(
      width: 34,
      height: 50,
      color: AppColors.surfaceElevated,
      child: Icon(
        Icons.movie_outlined,
        size: 16,
        color: AppColors.textMuted.withValues(alpha: 0.6),
      ),
    );
  }
}
