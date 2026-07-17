import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_colors.dart';
import '../../widgets/global/glass_catalog_search.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../desktop_window.dart';
import '../home/home_screen.dart';
import '../library/movies_screen.dart';
import '../library/shows_screen.dart';
import '../player_studio/player_studio_screen.dart';
import '../requests/requests_screen.dart';
import '../settings/playback_preferences_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  void _selectTab(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: [
                      HomeScreen(
                        embedded: isWide,
                        onNavigateToMovies: () => _selectTab(1),
                        onNavigateToShows: () => _selectTab(2),
                      ),
                      MoviesScreen(embedded: isWide),
                      ShowsScreen(embedded: isWide),
                      RequestsScreen(embedded: isWide),
                    ],
                  ),
                ),
                if (!isWide)
                  _MobileBottomNav(
                    selectedIndex: _selectedIndex,
                    onTabSelected: _selectTab,
                  ),
              ],
            ),
          ),
          if (isWide)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _DesktopGlassHeader(
                selectedIndex: _selectedIndex,
                onTabSelected: _selectTab,
                homeProvider: homeProvider,
                authProvider: authProvider,
              ),
            ),
          if (!isWide && _selectedIndex != 0)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, top: 6),
                  child: _AccountMenu(authProvider: authProvider),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopGlassHeader extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final HomeProvider homeProvider;
  final AuthProvider authProvider;

  const _DesktopGlassHeader({
    required this.selectedIndex,
    required this.onTabSelected,
    required this.homeProvider,
    required this.authProvider,
  });

  @override
  Widget build(BuildContext context) {
    return GlassHeaderStrip(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            28,
            6 + macOSWindowControlsTopInset,
            28,
            10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GlassBrand(onTap: () => onTabSelected(0)),
              const SizedBox(width: 20),
              GlassNavTab(
                label: 'Accueil',
                selected: selectedIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              GlassNavTab(
                label: 'Films',
                selected: selectedIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              GlassNavTab(
                label: 'Séries',
                selected: selectedIndex == 2,
                onTap: () => onTabSelected(2),
              ),
              GlassNavTab(
                label: 'Demandes',
                selected: selectedIndex == 3,
                onTap: () => onTabSelected(3),
              ),
              const Spacer(),
              const GlassCatalogSearch(
                collapsedWidth: 200,
                expandedWidth: 280,
              ),
              const SizedBox(width: 12),
              _IndexerActions(homeProvider: homeProvider),
              _AccountMenu(authProvider: authProvider),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  const _MobileBottomNav({
    required this.selectedIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                _BottomNavItem(
                  icon: Icons.home_rounded,
                  label: 'Accueil',
                  selected: selectedIndex == 0,
                  onTap: () => onTabSelected(0),
                ),
                _BottomNavItem(
                  icon: Icons.movie_rounded,
                  label: 'Films',
                  selected: selectedIndex == 1,
                  onTap: () => onTabSelected(1),
                ),
                _BottomNavItem(
                  icon: Icons.tv_rounded,
                  label: 'Séries',
                  selected: selectedIndex == 2,
                  onTap: () => onTabSelected(2),
                ),
                _BottomNavItem(
                  icon: Icons.add_circle_outline_rounded,
                  label: 'Demandes',
                  selected: selectedIndex == 3,
                  onTap: () => onTabSelected(3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? AppColors.textPrimary : AppColors.textMuted,
                size: 22,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.textPrimary : AppColors.textMuted,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IndexerActions extends StatelessWidget {
  final HomeProvider homeProvider;

  const _IndexerActions({required this.homeProvider});

  @override
  Widget build(BuildContext context) {
    if (homeProvider.isScanning) {
      return const _StatusBadge(label: 'Scan…');
    }
    if (homeProvider.isBackfillingMetadata) {
      return const _StatusBadge(label: 'Affiches…');
    }
    if (homeProvider.isExtractingSubtitles) {
      final stats = homeProvider.subtitleStats;
      final label = stats.total > 0
          ? 'Sous-titres ${stats.processed}/${stats.total}'
          : 'Sous-titres…';
      return _StatusBadge(label: label);
    }
    return const SizedBox.shrink();
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;

  const _StatusBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.95),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountMenu extends StatelessWidget {
  final AuthProvider authProvider;

  const _AccountMenu({required this.authProvider});

  @override
  Widget build(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context, listen: false);

    return PopupMenuButton<String>(
      tooltip: 'Menu',
      offset: const Offset(0, 44),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: AppColors.surfaceElevated.withValues(alpha: 0.96),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            authProvider.currentUser?.username ?? '',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const PopupMenuDivider(),
        if (!homeProvider.isScanning)
          const PopupMenuItem(
              value: 'scan', child: Text('Synchroniser la bibliothèque')),
        if (!homeProvider.isBackfillingMetadata)
          const PopupMenuItem(
              value: 'posters', child: Text('Mettre à jour les affiches')),
        if (!homeProvider.isExtractingSubtitles)
          const PopupMenuItem(
              value: 'subtitles', child: Text('Extraire les sous-titres')),
        const PopupMenuItem(value: 'studio', child: Text('Player Studio')),
        const PopupMenuItem(
            value: 'playback', child: Text('Préférences de lecture')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
      ],
      onSelected: (value) async {
        switch (value) {
          case 'scan':
            homeProvider.triggerLibraryScan();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Scan de la bibliothèque lancé…')),
            );
          case 'posters':
            homeProvider.triggerMetadataBackfill();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Mise à jour des affiches lancée…')),
            );
          case 'subtitles':
            try {
              await homeProvider.triggerSubtitleExtract();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Extraction des sous-titres lancée…')),
                );
              }
            } catch (_) {}
          case 'studio':
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayerStudioScreen()),
            );
          case 'playback':
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const PlaybackPreferencesScreen(),
              ),
            );
          case 'logout':
            authProvider.logout();
        }
      },
      child: GlassIconButton(
        size: 34,
        child: Text(
          (authProvider.currentUser?.username ?? '?')[0].toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
