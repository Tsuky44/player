import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/media_requests_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/empty_state.dart';
import 'request_detail_screen.dart';
import 'widgets/request_media_card.dart';

class RequestsScreen extends StatefulWidget {
  final bool embedded;

  const RequestsScreen({super.key, this.embedded = false});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MediaRequestsProvider>().load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 900) {
      context.read<MediaRequestsProvider>().loadMore();
    }
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      context.read<MediaRequestsProvider>().load(query: value);
    });
  }

  int _columns(double width) {
    if (width >= 1400) return 7;
    if (width >= 1100) return 6;
    if (width >= 800) return 5;
    if (width >= 550) return 4;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MediaRequestsProvider>();
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width >= 900 ? 48.0 : 16.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                widget.embedded ? MediaQuery.paddingOf(context).top + 66 : 28,
                horizontalPadding,
                20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Demander',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800, fontSize: 32)),
                  const SizedBox(height: 6),
                  const Text(
                      'Recherchez et demandez de nouveaux films et séries',
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Rechercher un film ou une série…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                                provider.load(query: '');
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('Tout')),
                      ButtonSegment(
                          value: 'movie',
                          label: Text('Films'),
                          icon: Icon(Icons.movie_outlined)),
                      ButtonSegment(
                          value: 'tv',
                          label: Text('Séries'),
                          icon: Icon(Icons.tv_outlined)),
                    ],
                    selected: {provider.type},
                    onSelectionChanged: (value) =>
                        provider.load(type: value.first),
                  ),
                ],
              ),
            ),
          ),
          if (provider.isLoading)
            const SliverFillRemaining(child: LoadingView())
          else if (provider.errorMessage != null && provider.items.isEmpty)
            SliverFillRemaining(
              child: ErrorStateView(
                  message: provider.errorMessage!, onRetry: provider.load),
            )
          else if (provider.items.isEmpty)
            const SliverFillRemaining(
              child: EmptyStateView(
                icon: Icons.search_off_rounded,
                title: 'Aucun média trouvé',
                message: 'Essayez une autre recherche ou un autre filtre.',
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  horizontalPadding, 8, horizontalPadding, 36),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _columns(width),
                  mainAxisSpacing: 24,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.56,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = provider.items[index];
                    return RequestMediaCard(
                      item: item,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => RequestDetailScreen(item: item)),
                      ),
                    );
                  },
                  childCount: provider.items.length,
                ),
              ),
            ),
          if (provider.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
    );
  }
}
