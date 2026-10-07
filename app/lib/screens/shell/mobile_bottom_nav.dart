import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_icons.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../theme/app_type.dart';
import '../../l10n/tr.dart';

/// La barre d'onglets du téléphone.
///
/// La plus grande surface structurelle de l'app sur téléphone : elle se lit en
/// verre sombre et dense, pas en voile blanc à 5 % — plus légère que n'importe
/// quel menu, elle laissait passer les affiches en pleine couleur sous les
/// libellés.
class MobileBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  final bool canRequestMedia;
  final bool canDownload;

  const MobileBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onTabSelected,
    required this.canRequestMedia,
    required this.canDownload,
  });

  @override
  Widget build(BuildContext context) {
    return GlassBarSurface(
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _BottomNavItem(
                icon: AppIcons.home,
                selectedIcon: AppIcons.homeSelected,
                label: tr('Accueil'),
                selected: selectedIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              _BottomNavItem(
                icon: AppIcons.movie,
                selectedIcon: AppIcons.movieSelected,
                label: tr('Films'),
                selected: selectedIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              _BottomNavItem(
                icon: AppIcons.series,
                selectedIcon: AppIcons.seriesSelected,
                label: tr('Séries'),
                selected: selectedIndex == 2,
                onTap: () => onTabSelected(2),
              ),
              if (canRequestMedia)
                _BottomNavItem(
                  icon: AppIcons.request,
                  selectedIcon: AppIcons.requestSelected,
                  label: tr('Demandes'),
                  selected: selectedIndex == 3,
                  onTap: () => onTabSelected(3),
                ),
              if (canDownload)
                _BottomNavItem(
                  icon: AppIcons.offline,
                  selectedIcon: AppIcons.offlineSelected,
                  label: tr('Hors ligne'),
                  selected: selectedIndex == 4,
                  onTap: () => onTabSelected(4),
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
    return Expanded(
      child: Semantics(
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
                Text(
                  label,
                  style: TextStyle(
                    color:
                        selected ? AppColors.textPrimary : AppColors.textMuted,
                    fontSize: AppType.caption,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
