import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/watch_list.dart';
import '../../providers/watch_lists_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import 'add_to_list_sheet.dart';

/// Le bouton « Ajouter à une liste » d'une fiche (ADR-0070) : le signet est
/// plein quand le titre est déjà dans une des listes du compte.
///
/// Absent quand le serveur ne tient pas de listes : ce qui n'est pas dessiné
/// ne produit pas de 404.
class AddToListButton extends StatefulWidget {
  const AddToListButton({super.key, required this.title});

  final ListableTitle title;

  @override
  State<AddToListButton> createState() => _AddToListButtonState();
}

class _AddToListButtonState extends State<AddToListButton> {
  bool _inList = false;

  /// La question n'est posée qu'une fois le serveur connu pour tenir des
  /// listes : la fiche peut s'ouvrir avant que la coquille l'ait appris.
  bool _probed = false;

  @override
  void didUpdateWidget(AddToListButton old) {
    super.didUpdateWidget(old);
    if (old.title.mediaId != widget.title.mediaId ||
        old.title.tmdbId != widget.title.tmdbId) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final provider = context.read<WatchListsProvider>();
    try {
      final lists = await provider.membership(widget.title);
      if (mounted) setState(() => _inList = lists.any((l) => l.contains));
    } catch (e) {
      // Le signet n'est qu'un indice : sans réponse, il reste creux, et la
      // feuille dira le vrai état à l'ouverture.
      debugPrint('AddToListButton: membership unavailable: $e');
    }
  }

  Future<void> _open() async {
    await showAddToListSheet(context, widget.title);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        context.select<WatchListsProvider, bool>((p) => p.isSupported);
    if (!supported) return const SizedBox.shrink();
    if (!_probed) {
      _probed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
    return IconButton(
      tooltip: _inList ? tr('Dans vos listes') : tr('Ajouter à une liste'),
      onPressed: _open,
      color: _inList ? AppColors.textPrimary : AppColors.textSecondary,
      icon: Icon(_inList ? AppIcons.inList : AppIcons.addToList),
    );
  }
}
