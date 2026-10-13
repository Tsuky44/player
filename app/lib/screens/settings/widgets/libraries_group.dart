import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/tr.dart';
import '../../../models/models.dart';
import '../../../providers/library_provider.dart';
import 'library_editor_dialog.dart';
import 'settings_ui.dart';

/// Les bibliothèques du serveur, pour qui l'administre (manage_settings) :
/// en ajouter autant qu'on veut, les renommer, changer leur dossier, les
/// retirer. Voir ADR-0058.
class LibrariesGroup extends StatefulWidget {
  const LibrariesGroup({super.key});

  @override
  State<LibrariesGroup> createState() => _LibrariesGroupState();
}

class _LibrariesGroupState extends State<LibrariesGroup> {
  @override
  void initState() {
    super.initState();
    // La coquille tient déjà cette liste ; on la relit pour qu'elle soit celle
    // du serveur à l'instant où on s'apprête à la changer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LibraryProvider>().loadLibraries();
    });
  }

  Future<void> _add() async {
    final provider = context.read<LibraryProvider>();
    final saved = await showLibraryEditor(
      context,
      onSubmit: (draft) => provider.createLibrary(
          name: draft.name, kind: draft.kind, path: draft.path),
    );
    if (saved && mounted) {
      showSettingsSnack(context,
          tr('Bibliothèque ajoutée. Le serveur analyse son dossier.'));
    }
  }

  Future<void> _edit(MediaLibrary library) async {
    final provider = context.read<LibraryProvider>();
    final saved = await showLibraryEditor(
      context,
      library: library,
      onSubmit: (draft) =>
          provider.updateLibrary(library, name: draft.name, path: draft.path),
    );
    if (saved && mounted) {
      showSettingsSnack(context, tr('Bibliothèque enregistrée.'));
    }
  }

  Future<void> _delete(MediaLibrary library) async {
    final confirmed = await confirmSettingsAction(
      context,
      title: tr('Supprimer « {0} » ?', [library.name]),
      message: tr('Ses titres quittent le catalogue, avec leur progression de '
          'lecture. Les fichiers restent sur le disque du serveur.'),
      confirmLabel: tr('Supprimer'),
    );
    if (!confirmed || !mounted) return;
    try {
      await context.read<LibraryProvider>().deleteLibrary(library);
      if (mounted) {
        showSettingsSnack(context, tr('Bibliothèque supprimée.'));
      }
    } catch (e) {
      if (mounted) {
        showSettingsSnack(
            context, settingsErrorText(e, tr('Échec de la suppression.')),
            error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<LibraryProvider>();
    final libraries = provider.libraries;
    // Un serveur d'avant les bibliothèques n'a que ses deux listes : rien à
    // renommer ni à ajouter tant qu'il n'est pas mis à jour.
    final legacy = libraries.any((library) => library.isLegacy);

    return SettingsGroup(
      title: tr('Bibliothèques'),
      footer: legacy
          ? null
          : tr('Une bibliothèque, c’est un dossier du serveur et le nom que '
              'vous lui donnez. Ajoutez-en autant que vous voulez.'),
      trailing: legacy
          ? null
          : TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Ajouter')),
            ),
      padded: !provider.librariesLoaded || legacy,
      children: [
        if (!provider.librariesLoaded)
          const SettingsLoading()
        else if (legacy)
          SettingsBanner(
            tr('Ce serveur est trop ancien pour cette fonction. Mettez-le à jour.'),
            tone: BannerTone.info,
          )
        else if (libraries.isEmpty)
          SettingsEmptyNote(
            tr('Aucune bibliothèque. Ajoutez un dossier du serveur pour '
                'commencer.'),
          )
        else
          for (final library in libraries)
            SettingsTile(
              icon: switch (library.kind) {
                LibraryKind.movies => Icons.movie_outlined,
                LibraryKind.shows => Icons.tv_rounded,
                LibraryKind.other => Icons.folder_outlined,
              },
              title: library.name,
              subtitle: library.path ?? '',
              onTap: () => _edit(library),
              showChevron: false,
              trailing: IconButton(
                tooltip: tr('Supprimer « {0} »', [library.name]),
                onPressed: () => _delete(library),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
      ],
    );
  }
}
