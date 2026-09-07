import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../navigation/catalog_navigation.dart';
import '../../providers/auth_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/app_network_image.dart';
import '../../widgets/global/media_detail_widgets.dart';
import '../../widgets/global/overlay_back_button.dart';

class CollectionScreen extends StatefulWidget {
  final int collectionId;
  final String? initialName;
  final String? initialBackdropUrl;

  const CollectionScreen({
    super.key,
    required this.collectionId,
    this.initialName,
    this.initialBackdropUrl,
  });

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  CollectionDetails? _collection;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = Provider.of<AuthProvider>(context, listen: false).apiClient;
      final collection = await api.getCollectionDetails(widget.collectionId);
      if (!mounted) return;
      setState(() {
        _collection = collection;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final collection = _collection;
    final ownedCount = collection?.parts.where((p) => p.isOwned).length ?? 0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _CollectionHeader(
              name: collection?.name ?? widget.initialName ?? '',
              overview: collection?.overview,
              backdropUrl: collection?.backdropUrl ?? widget.initialBackdropUrl,
              partsCount: collection?.parts.length ?? 0,
              ownedCount: ownedCount,
              onBack: () => Navigator.of(context).pop(),
            ),
          ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(64),
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            )
          else if (_failed || collection == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(64),
                child: Center(
                  child: Text(
                    'Impossible de charger cette saga.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: AppLayout.pageInsets(context, top: 28, bottom: 48),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  return SliverGrid(
                    gridDelegate: AppLayout.posterGridDelegate(
                      constraints.crossAxisExtent,
                      compact: AppLayout.isCompact(context),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = collection.parts[index];
                        return CatalogPosterCard(
                          item: item,
                          onTap: () => openCatalogItem(context, item),
                        );
                      },
                      childCount: collection.parts.length,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CollectionHeader extends StatelessWidget {
  final String name;
  final String? overview;
  final String? backdropUrl;
  final int partsCount;
  final int ownedCount;
  final VoidCallback onBack;

  const _CollectionHeader({
    required this.name,
    required this.overview,
    required this.backdropUrl,
    required this.partsCount,
    required this.ownedCount,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 380,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AppNetworkImage(
            url: backdropImageUrl(backdropUrl),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            decodeWidth: MediaQuery.sizeOf(context).width,
            placeholder: const ColoredBox(color: AppColors.surface),
            errorWidget: const ColoredBox(color: AppColors.surface),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, AppColors.background],
                stops: [0.25, 1.0],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.background.withValues(alpha: 0.85),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.8],
              ),
            ),
          ),
          Positioned(
            left: AppLayout.pagePadding(context),
            right: AppLayout.pagePadding(context),
            bottom: 32,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'SAGA',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  name,
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                ),
                if (partsCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    '$partsCount film${partsCount > 1 ? 's' : ''}'
                    '${ownedCount > 0 ? ' · $ownedCount dans ta bibliothèque' : ''}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 14),
                  ),
                ],
                if (overview != null && overview!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Text(
                      overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            top: 4,
            left: 8,
            child: OverlayBackButton(onPressed: onBack),
          ),
        ],
      ),
    );
  }
}
