import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_icons.dart';
import '../../../theme/app_type.dart';
import '../../../l10n/tr.dart';

/// Le menu « Métadonnées série » de la fiche d'une série.
///
/// Ses deux entrées appellent des routes que le serveur réserve à
/// `manage_library` (ADR-0001) : un compte sans ce droit n'a pas de menu du
/// tout, plutôt qu'un crayon qui mène à un refus.
class ShowMetadataMenu extends StatelessWidget {
  /// Relancer l'identification à partir du dossier local.
  final VoidCallback onRedetect;

  /// Choisir soi-même la fiche TMDB.
  final VoidCallback onPickOnTmdb;

  const ShowMetadataMenu({
    super.key,
    required this.onRedetect,
    required this.onPickOnTmdb,
  });

  @override
  Widget build(BuildContext context) {
    final canFixMetadata =
        context.select<AuthProvider, bool>((a) => a.permissions.manageLibrary);
    if (!canFixMetadata) return const SizedBox.shrink();

    return PopupMenuButton<VoidCallback>(
      tooltip: tr('Métadonnées série'),
      onSelected: (action) => action(),
      icon: const Icon(
        AppIcons.edit,
        color: AppColors.textSecondary,
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: onRedetect,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.identify),
            title: Text(tr('Relancer la détection auto')),
            subtitle: Text(
              tr('À partir du dossier / fichiers locaux'),
              style: TextStyle(fontSize: AppType.footnote),
            ),
          ),
        ),
        PopupMenuItem(
          value: onPickOnTmdb,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.search),
            title: Text(tr('Choisir sur TMDB')),
            subtitle: Text(
              tr('Correction manuelle de l’affiche'),
              style: TextStyle(fontSize: AppType.footnote),
            ),
          ),
        ),
      ],
    );
  }
}
