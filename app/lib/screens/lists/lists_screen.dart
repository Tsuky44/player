import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../desktop_window.dart';
import '../../l10n/tr.dart';
import '../../models/watch_list.dart';
import '../../providers/watch_lists_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import '../../tv/tv_mode.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/empty_state.dart';
import '../../widgets/global/watch_list_editor_dialog.dart';
import 'list_detail_screen.dart';
import 'widgets/watch_list_tile.dart';

/// L'onglet des listes (ADR-0070) : « À regarder plus tard » et les listes
/// du compte, puis celles que les autres comptes partagent.
class ListsScreen extends StatelessWidget {
  const ListsScreen({super.key, this.embedded = false});

  /// Sous l'en-tête de la coquille large : le contenu commence plus bas.
  final bool embedded;

  static SliverGridDelegate _gridDelegate(BuildContext context) {
    final compact = AppLayout.isCompact(context);
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: compact ? 220 : 300,
      mainAxisSpacing: compact ? 18 : 24,
      crossAxisSpacing: compact ? 12 : 20,
      // La mosaïque et ses deux lignes de texte.
      childAspectRatio: compact ? 1.05 : 1.2,
    );
  }

  static Future<void> _open(BuildContext context, WatchList list) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ListDetailScreen(listId: list.id, initial: list),
      ));

  static Future<void> _create(BuildContext context) async {
    final provider = context.read<WatchListsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showWatchListEditor(context);
    if (draft == null) return;
    try {
      final list = await provider.createList(
        name: draft.name,
        description: draft.description,
        isShared: draft.isShared,
      );
      if (context.mounted) await _open(context, list);
    } catch (e) {
      debugPrint('ListsScreen: create failed: $e');
      final data = e is DioException ? e.response?.data : null;
      messenger.showSnackBar(SnackBar(
        content: Text(data is Map && data['error'] != null
            ? data['error'].toString()
            : tr('La liste n’a pas pu être créée. Réessayez.')),
        backgroundColor: AppColors.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WatchListsProvider>();
    final padding = AppLayout.pagePadding(context);
    final compact = AppLayout.isCompact(context);
    final overview = provider.overview;

    Widget? state;
    if (!provider.hasLoaded && provider.errorMessage == null) {
      state = const LoadingView();
    } else if (!provider.hasLoaded) {
      state = ErrorStateView(
          message: provider.errorMessage!, onRetry: provider.load);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: () => provider.load(silent: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  embedded ? embeddedShellContentTopInset(context) : 28,
                  padding,
                  20,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Listes'),
                              style: Theme.of(context)
                                  .textTheme
                                  .displaySmall
                                  ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      fontSize: compact ? 26 : 32)),
                          const SizedBox(height: 6),
                          Text(
                            tr('Ce que vous voulez regarder, et ce que vous '
                                'recommandez aux autres'),
                            style:
                                const TextStyle(color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (compact)
                      IconButton.filledTonal(
                        tooltip: tr('Nouvelle liste'),
                        onPressed: () => _create(context),
                        icon: const Icon(AppIcons.add),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => _create(context),
                        icon: const Icon(AppIcons.add, size: 18),
                        label: Text(tr('Nouvelle liste')),
                      ),
                  ],
                ),
              ),
            ),
            if (state != null)
              SliverFillRemaining(hasScrollBody: false, child: state)
            else ...[
              _Section(title: tr('Mes listes')),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: SliverGrid(
                  gridDelegate: _gridDelegate(context),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final list = overview.mine[index];
                      return WatchListTile(
                        list: list,
                        autofocus: TvMode.isTv && index == 0,
                        onTap: () => _open(context, list),
                      );
                    },
                    childCount: overview.mine.length,
                  ),
                ),
              ),
              _Section(title: tr('Partagées par les autres')),
              if (overview.shared.isEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 48),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      tr('Personne n’a encore partagé de liste sur ce serveur.'),
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 48),
                  sliver: SliverGrid(
                    gridDelegate: _gridDelegate(context),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final list = overview.shared[index];
                        return WatchListTile(
                          list: list,
                          onTap: () => _open(context, list),
                        );
                      },
                      childCount: overview.shared.length,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final padding = AppLayout.pagePadding(context);
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(padding, 12, padding, 14),
      sliver: SliverToBoxAdapter(
        child: Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: AppType.title3,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
