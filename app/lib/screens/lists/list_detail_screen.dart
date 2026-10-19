import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/watch_list.dart';
import '../../providers/auth_provider.dart';
import '../../providers/watch_lists_provider.dart';
import '../../services/api_client.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_mode.dart';
import '../../utils/poster_url.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/overlay_back_button.dart';
import '../../widgets/global/poster_card.dart';
import '../../widgets/global/progress_pill.dart';
import '../../widgets/global/watch_list_editor_dialog.dart';
import '../library/movie_detail_screen.dart';
import '../library/show_detail_screen.dart';
import '../requests/request_detail_screen.dart';
import 'widgets/watch_list_tile.dart';

/// Une liste et ses titres (ADR-0070). Son propriétaire la modifie ; une liste
/// partagée par un autre compte se lit seulement.
class ListDetailScreen extends StatefulWidget {
  const ListDetailScreen({super.key, required this.listId, this.initial});

  final int listId;

  /// Le résumé déjà connu, pour peindre l'en-tête avant la réponse.
  final WatchList? initial;

  @override
  State<ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<ListDetailScreen> {
  /// En retrait : toucher une affiche la retire au lieu de l'ouvrir. Un mode
  /// plutôt qu'un appui long, que la télécommande n'a pas.
  bool _removing = false;

  WatchListsProvider get _provider => context.read<WatchListsProvider>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _provider.loadDetail(widget.listId, silent: true);
    });
  }

  static String _errorText(Object error, String fallback) {
    final data = error is DioException ? error.response?.data : null;
    return data is Map && data['error'] != null
        ? data['error'].toString()
        : fallback;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: AppColors.error));
  }

  Future<void> _open(WatchListItem item) async {
    final media = item.media;
    final Widget? page;
    if (media != null) {
      page = item.mediaType == WatchListMediaType.show
          ? ShowDetailScreen(show: media.media)
          : MovieDetailScreen(movieItem: media);
    } else if (context.read<AuthProvider>().permissions.requestMedia &&
        item.tmdbId > 0) {
      // Ce que le serveur n'a pas s'ouvre là où on peut le demander.
      page = RequestDetailScreen(item: item.toRequestItem());
    } else {
      page = null;
    }
    if (page == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(tr('« {0} » n’est pas encore sur le serveur', [item.title])),
      ));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page!));
    // La fiche a pu retirer ce titre de la liste, ou l'avoir fait avancer.
    if (mounted) _provider.loadDetail(widget.listId, silent: true);
  }

  Future<void> _remove(WatchListItem item) async {
    try {
      await _provider.removeItem(widget.listId, item.id);
    } catch (e) {
      debugPrint('ListDetailScreen: remove ${item.id} failed: $e');
      if (mounted) {
        _showError(_errorText(e, tr('Le titre n’a pas pu être retiré.')));
      }
    }
  }

  Future<void> _edit(WatchList list) async {
    final draft = await showWatchListEditor(context, existing: list);
    if (draft == null || !mounted) return;
    try {
      await _provider.updateList(list,
          name: draft.name,
          description: draft.description,
          isShared: draft.isShared);
    } catch (e) {
      debugPrint('ListDetailScreen: update failed: $e');
      if (mounted) {
        _showError(_errorText(e, tr('La liste n’a pas pu être modifiée.')));
      }
    }
  }

  Future<void> _delete(WatchList list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: Text(tr('Supprimer « {0} » ?', [list.displayName])),
        content: Text(list.isShared
            ? tr('La liste disparaîtra aussi pour les comptes avec qui vous '
                'la partagez. Les films et séries restent sur le serveur.')
            : tr('Les films et séries restent sur le serveur.')),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Annuler')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Supprimer')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final navigator = Navigator.of(context);
    try {
      await _provider.deleteList(list.id);
      navigator.pop();
    } catch (e) {
      debugPrint('ListDetailScreen: delete failed: $e');
      if (mounted) {
        _showError(_errorText(e, tr('La liste n’a pas pu être supprimée.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WatchListsProvider>();
    final detail = provider.detail(widget.listId);
    final list =
        detail?.list ?? provider.summary(widget.listId) ?? widget.initial;
    final items = detail?.items ?? const <WatchListItem>[];
    final padding = AppLayout.pagePadding(context);
    final error = provider.detailError(widget.listId);

    Widget body;
    if (detail == null && error != null) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorStateView(
            message: error, onRetry: () => provider.loadDetail(widget.listId)),
      );
    } else if (detail == null) {
      body =
          const SliverFillRemaining(hasScrollBody: false, child: LoadingView());
    } else if (items.isEmpty) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyStateView(
          icon: AppIcons.addToList,
          title: tr('Cette liste est vide'),
          message: list?.isMine ?? false
              ? tr('Ajoutez un film ou une série depuis sa fiche, avec le '
                  'signet. Les titres du catalogue des demandes aussi.')
              : tr('Son propriétaire n’y a encore rien mis.'),
        ),
      );
    } else {
      body = SliverPadding(
        padding: EdgeInsets.fromLTRB(padding, 8, padding, 48),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) => SliverGrid(
            gridDelegate: AppLayout.posterGridDelegate(
              constraints.crossAxisExtent,
              compact: AppLayout.isCompact(context),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = items[index];
                return _ItemCard(
                  item: item,
                  removing: _removing,
                  autofocus: TvMode.isTv && index == 0,
                  onTap: () => _removing ? _remove(item) : _open(item),
                );
              },
              childCount: items.length,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding - 8, 4, padding, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const OverlayBackButton(),
                    if (list != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: _Header(
                          list: list,
                          hasItems: items.isNotEmpty,
                          removing: _removing,
                          onEdit: () => _edit(list),
                          onDelete: () => _delete(list),
                          onToggleRemoving: () =>
                              setState(() => _removing = !_removing),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          body,
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.list,
    required this.hasItems,
    required this.removing,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleRemoving,
  });

  final WatchList list;
  final bool hasItems;
  final bool removing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggleRemoving;

  @override
  Widget build(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          list.displayName,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800, fontSize: compact ? 26 : 32),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(list.isShared ? AppIcons.sharedList : AppIcons.privateList,
                size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                watchListCaption(list),
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
        if (list.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(
              list.description,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppType.body,
                height: 1.5,
              ),
            ),
          ),
        ],
        if (list.isMine) ...[
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: Icon(
                    list.isWatchLater ? AppIcons.sharedList : AppIcons.edit,
                    size: 18),
                label: Text(list.isWatchLater ? tr('Partage') : tr('Modifier')),
              ),
              if (hasItems || removing)
                OutlinedButton.icon(
                  onPressed: onToggleRemoving,
                  icon: Icon(removing ? AppIcons.check : AppIcons.close,
                      size: 18),
                  label:
                      Text(removing ? tr('Terminé') : tr('Retirer des titres')),
                ),
              if (!list.isWatchLater)
                OutlinedButton.icon(
                  onPressed: onDelete,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error),
                  icon: const Icon(AppIcons.delete, size: 18),
                  label: Text(tr('Supprimer')),
                ),
            ],
          ),
          if (removing) ...[
            const SizedBox(height: 10),
            Text(tr('Touchez un titre pour le retirer de la liste.'),
                style: const TextStyle(color: AppColors.textMuted)),
          ],
        ],
      ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.removing,
    required this.onTap,
    this.autofocus = false,
  });

  final WatchListItem item;
  final bool removing;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final baseUrl = context.read<ApiClient>().baseUrl;
    final media = item.media;
    final progress = media?.percentWatched ?? 0;
    final inProgress = item.mediaType == WatchListMediaType.movie &&
        progress > 0 &&
        progress < 0.99;
    return Semantics(
      label: removing ? tr('Retirer {0} de la liste', [item.title]) : null,
      child: PosterCard(
        posterUrl: cardPosterUrl(item.posterUrl, serverBaseUrl: baseUrl),
        title: item.title,
        subtitle: item.isOnServer
            ? item.year
            : [
                if (item.year != null) item.year!,
                tr('Pas sur le serveur'),
              ].join(' · '),
        dimmed: !item.isOnServer,
        showPlayOnHover: false,
        autofocus: autofocus,
        placeholderIcon: item.mediaType == WatchListMediaType.show
            ? AppIcons.series
            : AppIcons.movie,
        onTap: onTap,
        overlays: [
          if (removing)
            Positioned(
              top: PosterCard.overlayInset,
              right: PosterCard.overlayInset,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: AppColors.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(AppIcons.close,
                    size: 16, color: AppColors.onAccent),
              ),
            ),
        ],
        footerOverlay: inProgress ? ProgressPill(value: progress) : null,
      ),
    );
  }
}
