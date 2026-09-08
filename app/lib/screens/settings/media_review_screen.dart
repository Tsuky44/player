import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/media_poster.dart';
import '../../widgets/global/metadata_fix_sheet.dart';

enum _ReviewFilter { all, unidentified, incomplete }

/// Persistent work queue for indexed movies and shows that still need a human
/// metadata decision. It lives under Settings > Library because every action
/// requires the manage_library permission.
class MediaReviewScreen extends StatefulWidget {
  const MediaReviewScreen({super.key});

  @override
  State<MediaReviewScreen> createState() => _MediaReviewScreenState();
}

class _MediaReviewScreenState extends State<MediaReviewScreen> {
  List<Media> _items = const [];
  bool _loading = true;
  String? _error;
  int? _workingId;
  _ReviewFilter _filter = _ReviewFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await context.read<ApiClient>().getMediaReviewQueue();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Impossible de charger les médias à vérifier.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _unidentified(Media item) => (item.tmdbId ?? 0) <= 0;

  bool _incomplete(Media item) =>
      !_unidentified(item) &&
      ((item.posterUrl?.trim().isEmpty ?? true) ||
          (item.overview?.trim().isEmpty ?? true) ||
          (item.releaseDate?.trim().isEmpty ?? true));

  List<Media> get _visibleItems => _items.where((item) {
        return switch (_filter) {
          _ReviewFilter.all => true,
          _ReviewFilter.unidentified => _unidentified(item),
          _ReviewFilter.incomplete => _incomplete(item),
        };
      }).toList();

  Future<void> _autoDetect(Media item) async {
    await _runUpdate(
      item,
      () => context.read<ApiClient>().redetectMediaMetadata(item.id),
      success: 'Détection terminée',
      failure: 'Aucune correspondance sûre — choisissez une fiche TMDB.',
    );
  }

  Future<void> _chooseMetadata(Media item) async {
    final api = context.read<ApiClient>();
    final fileName = _fileName(item.filePath);
    final choice = await MetadataFixSheet.show(
      context,
      api: api,
      initialQuery: item.title,
      type: item.type,
      fileName: item.type == MediaType.movie ? fileName : null,
    );
    if (choice == null || !mounted) return;
    await _runUpdate(
      item,
      () => api.rematchMediaMetadata(item.id, tmdbId: choice.tmdbId),
      success: 'Fiche mise à jour',
      failure: 'Impossible de mettre à jour la fiche.',
    );
  }

  Future<void> _runUpdate(
    Media item,
    Future<Media> Function() action, {
    required String success,
    required String failure,
  }) async {
    if (_workingId != null) return;
    setState(() => _workingId = item.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() {
        if (_hasReviewIssue(updated)) {
          _items = [
            for (final current in _items)
              if (current.id == updated.id) updated else current,
          ];
        } else {
          _items = _items.where((current) => current.id != item.id).toList();
        }
      });
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  bool _hasReviewIssue(Media item) =>
      _unidentified(item) ||
      (item.posterUrl?.trim().isEmpty ?? true) ||
      (item.overview?.trim().isEmpty ?? true) ||
      (item.releaseDate?.trim().isEmpty ?? true);

  String? _fileName(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    return path.split(RegExp(r'[\\/]+')).last;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleItems;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Médias à vérifier'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: AppLayout.pageInsets(context, top: 20, bottom: 12),
                sliver: SliverToBoxAdapter(child: _buildHeader()),
              ),
              if (_loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorState(message: _error!, onRetry: _load),
                )
              else if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(filtered: _items.isNotEmpty),
                )
              else
                SliverPadding(
                  padding: AppLayout.pageInsets(context, bottom: 36),
                  sliver: SliverList.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) => _ReviewCard(
                      item: visible[index],
                      busy: _workingId == visible[index].id,
                      onAutoDetect: () => _autoDetect(visible[index]),
                      onChoose: () => _chooseMetadata(visible[index]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_items.length} fiche${_items.length == 1 ? '' : 's'} à vérifier',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Tous les films et séries sans correspondance TMDB, affiche, synopsis ou date. '
          'La liste reste disponible après les scans et redémarrages.',
          style: TextStyle(color: AppColors.textSecondary, height: 1.4),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _filterChip(_ReviewFilter.all, 'Tous', _items.length),
            _filterChip(
              _ReviewFilter.unidentified,
              'Non identifiés',
              _items.where(_unidentified).length,
            ),
            _filterChip(
              _ReviewFilter.incomplete,
              'Métadonnées manquantes',
              _items.where(_incomplete).length,
            ),
          ],
        ),
      ],
    );
  }

  Widget _filterChip(_ReviewFilter value, String label, int count) {
    return ChoiceChip(
      selected: _filter == value,
      label: Text('$label  $count'),
      onSelected: (_) => setState(() => _filter = value),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final Media item;
  final bool busy;
  final VoidCallback onAutoDetect;
  final VoidCallback onChoose;

  const _ReviewCard({
    required this.item,
    required this.busy,
    required this.onAutoDetect,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    final issues = <String>[
      if ((item.tmdbId ?? 0) <= 0) 'Non identifié',
      if (item.posterUrl?.trim().isEmpty ?? true) 'Affiche manquante',
      if (item.overview?.trim().isEmpty ?? true) 'Synopsis manquant',
      if (item.releaseDate?.trim().isEmpty ?? true) 'Date manquante',
    ];
    final filename = item.filePath?.split(RegExp(r'[\\/]+')).last;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaPoster(media: item, width: 64, height: 96, borderRadius: 10),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    item.type == MediaType.show ? 'Série' : 'Film',
                    if (filename != null && filename.isNotEmpty) filename,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final issue in issues) _IssueChip(issue)],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : onAutoDetect,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_fix_high_rounded, size: 17),
                      label:
                          Text(compact ? 'Auto' : 'Détecter automatiquement'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : onChoose,
                      icon: const Icon(Icons.search_rounded, size: 17),
                      label: const Text('Choisir la fiche'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueChip extends StatelessWidget {
  final String label;
  const _IssueChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.warning,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool filtered;
  const _EmptyState({required this.filtered});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_rounded,
                size: 48, color: AppColors.success),
            const SizedBox(height: 14),
            Text(
              filtered
                  ? 'Aucun média dans ce filtre'
                  : 'Toutes les fiches sont complètes',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}
