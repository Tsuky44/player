import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/interface_tour/tour_anchor.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';
import '../library/library_screen.dart';
import 'shell_tabs.dart';

/// La barre d'onglets du téléphone.
///
/// La plus grande surface structurelle de l'app sur téléphone : elle se lit en
/// verre sombre et dense, pas en voile blanc à 5 % — plus légère que n'importe
/// quel menu, elle laissait passer les affiches en pleine couleur sous les
/// libellés.
class MobileBottomNav extends StatelessWidget {
  /// L'identifiant de l'onglet affiché (voir [ShellTabs]).
  final String selected;
  final ValueChanged<String> onTabSelected;

  /// Les bibliothèques du serveur (ADR-0058).
  final List<MediaLibrary> libraries;

  final bool canRequestMedia;
  final bool canDownload;

  /// Le serveur tient des listes (ADR-0070).
  final bool canUseLists;

  /// Au-delà, les bibliothèques ne tiennent plus côte à côte entre l'accueil
  /// et les deux derniers onglets : un seul onglet les réunit et ouvre leur
  /// liste.
  static const int maxInlineLibraries = 2;

  const MobileBottomNav({
    super.key,
    required this.selected,
    required this.onTabSelected,
    required this.libraries,
    required this.canRequestMedia,
    required this.canDownload,
    this.canUseLists = false,
  });

  Future<void> _pickLibrary(BuildContext context) async {
    final picked = await showModalBottomSheet<MediaLibrary>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final library in libraries)
              ListTile(
                leading: Icon(
                  libraryIcon(library.kind,
                      selected: selected == ShellTabs.library(library)),
                  color: AppColors.textPrimary,
                ),
                title: Text(ShellTabs.label(library)),
                trailing: selected == ShellTabs.library(library)
                    ? const Icon(AppIcons.check, color: AppColors.textPrimary)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(library),
              ),
          ],
        ),
      ),
    );
    if (picked != null) onTabSelected(ShellTabs.library(picked));
  }

  @override
  Widget build(BuildContext context) {
    final inline = libraries.length <= maxInlineLibraries;
    return GlassBarSurface(
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              // L'accueil et les bibliothèques d'un seul tenant : c'est ainsi
              // que la présentation de l'interface les montre.
              Expanded(
                flex: inline ? 1 + libraries.length : 2,
                child: TourTarget(
                  anchor: TourAnchor.library,
                  child: Row(
                    children: [
                      Expanded(
                        child: _BottomNavItem(
                          icon: AppIcons.home,
                          selectedIcon: AppIcons.homeSelected,
                          label: tr('Accueil'),
                          selected: selected == ShellTabs.home,
                          onTap: () => onTabSelected(ShellTabs.home),
                        ),
                      ),
                      if (inline)
                        for (final library in libraries)
                          Expanded(
                            child: _BottomNavItem(
                              icon: libraryIcon(library.kind),
                              selectedIcon:
                                  libraryIcon(library.kind, selected: true),
                              label: ShellTabs.label(library),
                              selected:
                                  selected == ShellTabs.library(library),
                              onTap: () =>
                                  onTabSelected(ShellTabs.library(library)),
                            ),
                          )
                      else
                        Expanded(
                          child: _BottomNavItem(
                            icon: AppIcons.collection,
                            selectedIcon: AppIcons.collection,
                            label: tr('Bibliothèques'),
                            selected: ShellTabs.isLibrary(selected),
                            onTap: () => _pickLibrary(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (canRequestMedia)
                Expanded(
                  child: TourTarget(
                    anchor: TourAnchor.requests,
                    child: _BottomNavItem(
                      icon: AppIcons.request,
                      selectedIcon: AppIcons.requestSelected,
                      label: tr('Demandes'),
                      selected: selected == ShellTabs.requests,
                      onTap: () => onTabSelected(ShellTabs.requests),
                    ),
                  ),
                ),
              if (canUseLists)
                Expanded(
                  child: _BottomNavItem(
                    icon: AppIcons.lists,
                    selectedIcon: AppIcons.listsSelected,
                    label: tr('Listes'),
                    selected: selected == ShellTabs.lists,
                    onTap: () => onTabSelected(ShellTabs.lists),
                  ),
                ),
              if (canDownload)
                Expanded(
                  child: TourTarget(
                    anchor: TourAnchor.downloads,
                    child: _BottomNavItem(
                      icon: AppIcons.offline,
                      selectedIcon: AppIcons.offlineSelected,
                      label: tr('Hors ligne'),
                      selected: selected == ShellTabs.downloads,
                      onTap: () => onTabSelected(ShellTabs.downloads),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  final IconData icon;

  /// Plein quand l'onglet est actif, creux sinon : la sélection se lit à la
  /// forme autant qu'à la couleur.
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Blanc et non bleu : l'accent est réservé au focus et à la
              // progression, et cinq onglets en bas d'écran ne sont ni l'un
              // ni l'autre.
              Icon(
                selected ? selectedIcon : icon,
                color: selected ? AppColors.textPrimary : AppColors.textMuted,
                size: 24,
              ),
              const SizedBox(height: 4),
              // Le nom d'une bibliothèque est libre : au-delà de la largeur
              // de l'onglet il se coupe, il ne déborde pas sur le voisin.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        selected ? AppColors.textPrimary : AppColors.textMuted,
                    fontSize: AppType.caption,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
