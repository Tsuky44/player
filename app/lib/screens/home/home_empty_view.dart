import 'package:flutter/material.dart';

import '../../l10n/tr.dart';
import '../../models/models.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_icons.dart';
import '../../widgets/global/empty_state.dart';
import '../settings/settings_screen.dart';

/// L'accueil d'un serveur qui n'a encore rien à montrer.
///
/// Deux raisons, deux messages. Sans aucune bibliothèque — un serveur neuf
/// n'en a pas (ADR-0058) — il n'y a rien à analyser : on mène l'administrateur
/// là où il déclare ses dossiers. Avec des bibliothèques encore vides, c'est
/// une analyse qu'il reste à lancer.
///
/// Chaque action n'est tendue qu'à qui le serveur la permet (ADR-0001) : aux
/// autres comptes on dit qui peut agir, au lieu d'un bouton qui échoue.
class HomeEmptyView extends StatelessWidget {
  const HomeEmptyView({
    super.key,
    required this.libraries,
    required this.permissions,
    required this.homeProvider,
  });

  /// Les bibliothèques du serveur ; null tant qu'on ne les connaît pas.
  final List<MediaLibrary>? libraries;
  final Permissions permissions;
  final HomeProvider homeProvider;

  @override
  Widget build(BuildContext context) {
    final libraries = this.libraries;
    if (libraries != null && libraries.isEmpty) {
      if (!permissions.manageSettings) {
        return EmptyStateView(
          icon: AppIcons.collection,
          title: tr('Aucune bibliothèque'),
          message: tr('L’administrateur de ce serveur n’a pas encore déclaré '
              'de bibliothèque.'),
        );
      }
      return EmptyStateView(
        icon: AppIcons.collection,
        title: tr('Aucune bibliothèque'),
        message: tr('Choisissez un dossier du serveur et donnez-lui le nom que '
            'vous voulez. Vous pouvez en créer autant que nécessaire.'),
        actionLabel: tr('Ajouter une bibliothèque'),
        actionIcon: AppIcons.add,
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsScreen(
                initialSection: SettingsSections.library),
          ),
        ),
      );
    }

    if (!permissions.manageLibrary) {
      return EmptyStateView(
        icon: AppIcons.collection,
        title: tr('Bibliothèque vide'),
        message: tr('Rien sur ce serveur pour l’instant. Son administrateur '
            'peut en ajouter.'),
      );
    }
    return EmptyStateView(
      icon: AppIcons.collection,
      title: tr('Bibliothèque vide'),
      message: tr('Ajoutez des fichiers dans les dossiers de vos '
          'bibliothèques, puis lancez une synchronisation.'),
      actionLabel: tr('Synchroniser'),
      onAction: homeProvider.triggerLibraryScan,
      secondaryActionLabel: tr('Extraire les sous-titres'),
      onSecondaryAction: homeProvider.triggerSubtitleExtract,
    );
  }
}
