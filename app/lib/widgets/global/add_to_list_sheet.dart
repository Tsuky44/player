import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/watch_list.dart';
import '../../providers/watch_lists_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_type.dart';
import 'empty_state.dart';
import 'watch_list_editor_dialog.dart';

/// Ouvre la feuille « Ajouter à une liste » pour [title] (ADR-0070).
Future<void> showAddToListSheet(BuildContext context, ListableTitle title) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    builder: (_) => AddToListSheet(title: title),
  );
}

/// Les listes du compte, cochées quand elles ont déjà le titre. Cocher range
/// le titre, décocher le retire : chaque geste part tout de suite au serveur,
/// et se défait à l'écran s'il échoue.
class AddToListSheet extends StatefulWidget {
  const AddToListSheet({super.key, required this.title});

  final ListableTitle title;

  @override
  State<AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends State<AddToListSheet> {
  List<WatchList>? _lists;
  String? _error;
  final Set<int> _pending = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final lists =
          await context.read<WatchListsProvider>().membership(widget.title);
      if (mounted) setState(() => _lists = lists);
    } catch (e) {
      debugPrint('AddToListSheet: lists unavailable: $e');
      if (mounted) {
        setState(() => _error = tr('Impossible de charger vos listes.'));
      }
    }
  }

  void _replace(WatchList list) {
    setState(() {
      _lists = [
        for (final l in _lists ?? const <WatchList>[])
          l.id == list.id ? list : l,
      ];
    });
  }

  Future<void> _toggle(WatchList list) async {
    if (_pending.contains(list.id)) return;
    final provider = context.read<WatchListsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final wasIn = list.contains;
    _pending.add(list.id);
    // Coché ou décoché tout de suite ; -1 tient la place de l'élément que le
    // serveur va créer.
    _replace(list.withMembership(wasIn ? 0 : -1));
    try {
      if (wasIn) {
        await provider.removeItem(list.id, list.containsItemId!);
        if (mounted) _replace(list.withMembership(0));
      } else {
        final item = await provider.addTitle(list.id, widget.title);
        if (mounted) _replace(list.withMembership(item.id));
      }
    } catch (e) {
      debugPrint('AddToListSheet: toggle ${list.id} failed: $e');
      if (mounted) _replace(list);
      messenger.showSnackBar(SnackBar(
        content: Text(_errorText(e)),
        backgroundColor: AppColors.error,
      ));
    } finally {
      _pending.remove(list.id);
    }
  }

  Future<void> _create() async {
    final draft = await showWatchListEditor(context);
    if (draft == null || !mounted) return;
    final provider = context.read<WatchListsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final created = await provider.createList(
        name: draft.name,
        description: draft.description,
        isShared: draft.isShared,
      );
      final item = await provider.addTitle(created.id, widget.title);
      if (!mounted) return;
      setState(() {
        _lists = [
          ...?_lists,
          WatchList(
            id: created.id,
            kind: created.kind,
            name: created.name,
            description: created.description,
            isShared: created.isShared,
            isMine: true,
            owner: created.owner,
            itemCount: 1,
            posters: created.posters,
            containsItemId: item.id,
          ),
        ];
      });
    } catch (e) {
      debugPrint('AddToListSheet: create failed: $e');
      messenger.showSnackBar(SnackBar(
        content: Text(_errorText(e)),
        backgroundColor: AppColors.error,
      ));
    }
  }

  static String _errorText(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['error'] != null) return data['error'].toString();
    }
    return tr('La liste n’a pas pu être modifiée. Réessayez.');
  }

  @override
  Widget build(BuildContext context) {
    final lists = _lists;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Ajouter à une liste'),
                      style: const TextStyle(
                          fontSize: AppType.title3,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 4),
                  Text(widget.title.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            ),
            if (_error != null)
              Flexible(
                child: ErrorStateView(message: _error!, onRetry: _load),
              )
            else if (lists == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (index, list) in lists.indexed)
                      _ListRow(
                        list: list,
                        autofocus: index == 0,
                        busy: _pending.contains(list.id),
                        onTap: () => _toggle(list),
                      ),
                    ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 24),
                      leading: const Icon(AppIcons.add,
                          color: AppColors.textPrimary),
                      title: Text(tr('Nouvelle liste')),
                      onTap: _create,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.list,
    required this.onTap,
    this.autofocus = false,
    this.busy = false,
  });

  final WatchList list;
  final VoidCallback onTap;
  final bool autofocus;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final checked = list.contains;
    return Semantics(
      checked: checked,
      child: ListTile(
        autofocus: autofocus,
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        leading: Icon(
          list.isWatchLater
              ? (checked ? AppIcons.inList : AppIcons.addToList)
              : list.isShared
                  ? AppIcons.sharedList
                  : AppIcons.privateList,
          color: AppColors.textPrimary,
        ),
        title: Text(list.displayName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          list.isShared ? tr('Partagée') : tr('Privée'),
          style: const TextStyle(color: AppColors.textMuted),
        ),
        trailing: Icon(
          checked ? AppIcons.check : null,
          color: busy ? AppColors.textMuted : AppColors.accent,
        ),
        onTap: onTap,
      ),
    );
  }
}
