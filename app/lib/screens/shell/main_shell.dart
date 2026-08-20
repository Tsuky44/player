import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/glass_catalog_search.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/sticky_glass_search.dart';
import '../../desktop_window.dart';
import '../../tv/tv_mode.dart';
import '../../tv/tv_pairing_link.dart';
import '../settings/tv_pairing_screen.dart';
import '../home/home_screen.dart';
import '../library/movies_screen.dart';
import '../library/shows_screen.dart';
import '../requests/requests_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // A QR scanned on the TV parks its code before the app even knows whether
    // anyone is signed in. This is the first moment there is both a session and
    // a navigator, so it is where the approval screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final code = TvPairingLink.take();
      if (code == null || !mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TvPairingScreen(initialCode: code)),
      );
    });
  }

  void _selectTab(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    // A television always takes the wide chrome: the bottom tab bar is a thumb
    // target, and there is no thumb. Some sticks report barely 960 logical
    // pixels, which would otherwise land them in the phone layout.
    final isWide = AppLayout.isWide(context) || TvScope.of(context);

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
                    // An IndexedStack keeps every tab in the tree and paints
                    // one. That is what makes switching instant, and it is also
                    // what would let the D-pad walk into posters nobody can
                    // see: focus traversal reads the widget tree, not what is
                    // on screen. Excluding the hidden tabs keeps the remote
                    // inside the tab the user is actually looking at.
                    children: [
                      for (final (index, screen) in <Widget>[
                        HomeScreen(
                          embedded: isWide,
                          onNavigateToMovies: () => _selectTab(1),
                          onNavigateToShows: () => _selectTab(2),
                        ),
                        MoviesScreen(embedded: isWide),
                        ShowsScreen(embedded: isWide),
                        RequestsScreen(embedded: isWide),
                      ].indexed)
                        ExcludeFocus(
                          excluding: index != _selectedIndex,
                          child: screen,
                        ),
                    ],
                  ),
                ),
                if (!isWide)
                  _MobileBottomNav(
                    selectedIndex: _selectedIndex,
                    onTabSelected: _selectTab,
                    canRequestMedia: authProvider.permissions.requestMedia,
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
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
                  child: Row(
                    children: [
                      const Spacer(),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: const InlineCatalogSearch(),
                      ),
                      const SizedBox(width: 8),
                      const AppDownloadButton(),
                      AccountMenu(authProvider: authProvider),
                    ],
                  ),
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
    final header = SafeArea(
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
            // The whole request catalog sits behind request_media server-side,
            // so an account without it gets no entry point either.
            if (authProvider.permissions.requestMedia)
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
            const AppDownloadButton(),
            AccountMenu(authProvider: authProvider),
          ],
        ),
      ),
    );

    return GlassHeaderStrip(
      child: AppPlatform.isMacOS
          ? Stack(
              children: [
                // Empty zones (title bar / spacer) drag the window; buttons
                // above still receive hits and don't block trackpad scroll.
                const Positioned.fill(
                  child: WindowDragArea(child: SizedBox.expand()),
                ),
                header,
              ],
            )
          : header,
    );
  }
}

class _MobileBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  final bool canRequestMedia;

  const _MobileBottomNav({
    required this.selectedIndex,
    required this.onTabSelected,
    required this.canRequestMedia,
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
            child: SizedBox(
              height: 56,
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
                  if (canRequestMedia)
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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: selected ? AppColors.primary : AppColors.textMuted,
                size: 24,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.textPrimary : AppColors.textMuted,
                  fontSize: 11,
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
    if (homeProvider.isRedetectingAll) {
      final stats = homeProvider.redetectAllProgress;
      final label = stats.total > 0
          ? 'Match ${stats.processed}/${stats.total}'
          : 'Match…';
      return _StatusBadge(label: label);
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

