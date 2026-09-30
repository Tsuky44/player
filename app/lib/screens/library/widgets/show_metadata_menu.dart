import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../theme/app_colors.dart';

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
      tooltip: 'Métadonnées série',
      onSelected: (action) => action(),
      icon: const Icon(
        Icons.edit_note_rounded,
        color: AppColors.textSecondary,
      ),
      color: AppColors.surfaceElevated,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: onRedetect,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.auto_fix_high_outlined),
            title: Text('Relancer la détection auto'),
            subtitle: Text(
              'À partir du dossier / fichiers locaux',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        PopupMenuItem(
          value: onPickOnTmdb,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.search_rounded),
            title: Text('Choisir sur TMDB'),
            subtitle: Text(
              'Correction manuelle de l’affiche',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
