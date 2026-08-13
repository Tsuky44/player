import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import 'onyx_mark.dart';

class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final bool showLogo;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final VoidCallback? onLogoTap;

  const AppTopBar({
    super.key,
    this.showLogo = true,
    this.actions,
    this.bottom,
    this.onLogoTap,
  });

  @override
  Size get preferredSize => Size.fromHeight(
        kToolbarHeight + (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.navBackground,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      title: showLogo
          ? GestureDetector(
              onTap: onLogoTap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const OnyxMark(size: 32),
                  const SizedBox(width: 10),
                  Text(
                    'Onyx',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          fontSize: 18,
                        ),
                  ),
                ],
              ),
            )
          : null,
      actions: actions,
      bottom: bottom,
    );
  }
}

class ScrollAwareNavBar extends StatelessWidget {
  final double scrollOffset;
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  const ScrollAwareNavBar({
    super.key,
    required this.scrollOffset,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    final opaque = scrollOffset > 80;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: opaque ? AppColors.background : Colors.transparent,
        boxShadow: opaque
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8)]
            : null,
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
          child: Row(
            children: [
              const OnyxMark(size: 32),
              const SizedBox(width: 10),
              Text(
                'Onyx',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      fontSize: 18,
                    ),
              ),
              const SizedBox(width: 32),
              _NavTab(
                label: 'Accueil',
                selected: selectedIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              _NavTab(
                label: 'Films',
                selected: selectedIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              _NavTab(
                label: 'Séries',
                selected: selectedIndex == 2,
                onTap: () => onTabSelected(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.textPrimary : AppColors.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}
