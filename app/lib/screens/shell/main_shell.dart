import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../utils/app_platform.dart';
import '../../utils/window_controls.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../services/download_manager.dart';
import '../../services/server_reachability.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/app_download_button.dart';
import '../../widgets/global/glass_catalog_search.dart';
import '../../widgets/global/glass_chrome.dart';
import '../../widgets/global/sticky_glass_search.dart';
import '../../desktop_window.dart';
import '../../navigation/shell_navigator.dart';
import '../../tv/tv_focus_memory.dart';
import '../../tv/tv_mode.dart';
import '../../tv/tv_pairing_link.dart';
import '../settings/tv_pairing_screen.dart';
import '../downloads/downloads_screen.dart';
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

  /// Un nœud par onglet de l'en-tête, pour que Retour puisse y ramener la
  /// télécommande. Indexés comme les écrans de l'[IndexedStack].
  final List<FocusNode> _tabNodes = List<FocusNode>.generate(
    5,
    (index) => FocusNode(debugLabel: 'nav-tab-$index'),
  );

  /// Observe l'en-tête entier — onglets, recherche, compte — sans jamais
  /// prendre le focus lui-même.
  final FocusNode _headerNode = FocusNode(
    debugLabel: 'shell-header',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Le moment où Retour a été pressé une première fois sur l'accueil. Un
  /// second appui dans [_exitWindow] quitte l'app.
  DateTime? _exitArmedAt;
  static const Duration _exitWindow = Duration(seconds: 3);

  /// Les onglets réellement montés dans l'[IndexedStack].
  ///
  /// La pile les gardait tous les cinq vivants dès la première image. Aucun
  /// n'est gratuit : films et séries construisent chacun la grille de toute la
  /// médiathèque, et films, séries et demandes lancent chacun leur requête
  /// depuis `initState` — quatre écrans et trois appels réseau derrière
  /// l'accueil, pendant que l'accueil, lui, attend sa réponse sur la même
  /// connexion. Les onglets non visités arrivent donc plus tard
  /// ([_warmOtherTabs]), et une fois montés ils le restent : c'est ce qui rend
  /// le changement d'onglet instantané, et c'était la seule raison de les
  /// monter tôt.
  final Set<int> _mountedTabs = {0};
  Timer? _warmTimer;

  /// Monte les autres onglets une fois l'accueil passé.
  ///
  /// Le délai est celui de [PlayerEnginePool.prewarm], et pour la même raison :
  /// le but est d'occuper un moment creux, pas de disputer le démarrage à ce
  /// que l'utilisateur regarde.
  static const Duration _warmDelay = Duration(seconds: 3);

  void _warmOtherTabs() {
    if (_mountedTabs.length == _tabNodes.length) return;
    setState(() {
      for (var index = 0; index < _tabNodes.length; index++) {
        _mountedTabs.add(index);
      }
    });
  }

  @override
  void dispose() {
    _warmTimer?.cancel();
    for (final node in _tabNodes) {
      node.dispose();
    }
    _headerNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // A QR scanned on the TV parks its code before the app even knows whether
    // anyone is signed in. This is the first moment there is both a session and
    // a navigator, so it is where the approval screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _warmTimer = Timer(_warmDelay, () {
        if (mounted) _warmOtherTabs();
      });
      final code = TvPairingLink.take();
      if (code == null) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TvPairingScreen(initialCode: code)),
      );
    });
  }

  /// Vrai quand une page (fiche d'un média, d'une personne…) est ouverte
  /// par-dessus les onglets, dans [shellNavigatorKey].
  bool _pageOpen = false;

  void _selectTab(int index) {
    // Un onglet choisi depuis une fiche ramène aux onglets, y compris celui
    // qui était déjà sélectionné : c'est le chemin du retour à la liste.
    if (_pageOpen) {
      shellNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    if (_selectedIndex == index) return;
    // Un onglet choisi avant son tour se monte maintenant : l'attente d'une
    // image vaut mieux que celle de la fin du délai.
    setState(() {
      _mountedTabs.add(index);
      _selectedIndex = index;
    });
  }

  /// Les onglets dans un navigateur à eux, pour que les fiches s'ouvrent sous
  /// la barre de navigation au lieu de la recouvrir. Le lecteur, lui, part
  /// dans le navigateur racine : il doit couvrir tout l'écran.
  ///
  /// Sur grand écran la barre flotte au-dessus du contenu. Les pages ouvertes
  /// reçoivent sa hauteur comme marge du haut — c'est ce que leurs boutons
  /// retour et leurs SafeArea lisent déjà pour éviter la barre d'état. Les
  /// onglets gardent la marge d'origine : ils réservent la place eux-mêmes,
  /// voir [embeddedShellContentTopInset].
  Widget _buildPageNavigator(
    BuildContext context, {
    required Widget tabs,
    required bool isWide,
  }) {
    final media = MediaQuery.of(context);
    Widget navigator = Navigator(
      key: shellNavigatorKey,
      pages: [
        MaterialPage<void>(
          key: const ValueKey('tabs'),
          child: MediaQuery(data: media, child: tabs),
        ),
      ],
      // La page des onglets n'est jamais retirée : il n'y a rien à mettre à
      // jour quand une fiche s'en va.
      onDidRemovePage: (_) {},
    );
    if (isWide) {
      final headerHeight = shellHeaderHeight(context);
      navigator = MediaQuery(
        data: media.copyWith(
          padding: media.padding.copyWith(top: headerHeight),
          viewPadding: media.viewPadding.copyWith(top: headerHeight),
        ),
        child: navigator,
      );
    }
    return NavigatorPopHandler<Object?>(
      // Retour (Android, souris, clavier) ferme d'abord la fiche ouverte.
      onPopWithResult: (_) => shellNavigatorKey.currentState?.maybePop(),
      child: NotificationListener<NavigationNotification>(
        onNotification: (notification) {
          if (notification.canHandlePop != _pageOpen) {
            setState(() => _pageOpen = notification.canHandlePop);
          }
          return false;
        },
        child: navigator,
      ),
    );
  }

  /// La touche Retour d'une télécommande, sur l'écran principal.
  ///
  /// Elle remonte d'un cran à la fois, comme sur Android TV : du contenu vers
  /// l'onglet affiché dans l'en-tête, d'un autre onglet vers l'accueil, et de
  /// l'accueil vers la sortie — après confirmation, parce qu'un appui de trop
  /// en remontant ne doit pas fermer l'app.
  void _handleTvBack() {
    if (!_headerNode.hasFocus) {
      _focusTab(_selectedIndex);
      return;
    }
    if (_selectedIndex != 0) {
      _selectTab(0);
      _focusTab(0);
      return;
    }
    final now = DateTime.now();
    final armed = _exitArmedAt;
    if (armed != null && now.difference(armed) < _exitWindow) {
      SystemNavigator.pop();
      return;
    }
    _exitArmedAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Appuyez de nouveau sur Retour pour quitter'),
        duration: _exitWindow,
      ));
  }

  void _focusTab(int index) {
    // Un onglet absent de l'en-tête (pas de droit de demande, pas de
    // téléchargements sur cet appareil) n'a pas de nœud monté : l'accueil, lui,
    // est toujours là.
    final node = _tabNodes[index].context != null ? _tabNodes[index] : _tabNodes[0];
    node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // L'en-tête et la barre d'onglets sont deux verres posés sur la même
    // page, l'un en haut l'autre en bas : ils lisent la même image et n'ont
    // donc besoin de la lire qu'une fois. Voir l'ADR-0025. Ce qui vient en
    // surimpression — le menu de compte, la recherche du catalogue — n'entre
    // pas dans le groupe : il couvre le chrome et doit le flouter.
    return BackdropGroup(child: _buildShell(context));
  }

  Widget _buildShell(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    final downloads = Provider.of<DownloadManager>(context);

    // Une session ouverte sur un profil en cache n'a rien à montrer d'autre que
    // le disque : chaque autre onglet ne saurait afficher qu'une erreur. On les
    // retire plutôt que de les laisser échouer, et ils reviennent d'eux-mêmes
    // dès que le serveur répond de nouveau.
    if (authProvider.isOfflineSession) {
      return _OfflineShell(authProvider: authProvider);
    }
    // A television always takes the wide chrome: the bottom tab bar is a thumb
    // target, and there is no thumb. Some sticks report barely 960 logical
    // pixels, which would otherwise land them in the phone layout.
    final isTv = TvScope.of(context);
    final isWide = AppLayout.isWide(context) || isTv;

    final tabs = IndexedStack(
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
          DownloadsScreen(embedded: isWide),
        ].indexed)
          ExcludeFocus(
            excluding: index != _selectedIndex,
            // Redescendre de l'en-tête ramène là où l'on était
            // dans cet onglet — voir [TvFocusMemory].
            child: _mountedTabs.contains(index)
                ? TvFocusMemory(child: screen)
                : const SizedBox.shrink(),
          ),
      ],
    );

    final shell = Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Expanded(
                  // Pas de navigateur imbriqué sur un téléviseur : les fiches
                  // y restent en plein écran, avec le parcours au D-pad et le
                  // Retour de [_handleTvBack] tels qu'ils sont réglés.
                  child: isTv
                      ? tabs
                      : _buildPageNavigator(context, tabs: tabs, isWide: isWide),
                ),
                if (!isWide)
                  _MobileBottomNav(
                    selectedIndex: _selectedIndex,
                    onTabSelected: _selectTab,
                    canRequestMedia: authProvider.permissions.requestMedia,
                    canDownload: downloads.isSupported,
                  ),
              ],
            ),
          ),
          if (isWide)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Focus(
                focusNode: _headerNode,
                canRequestFocus: false,
                skipTraversal: true,
                child: _DesktopGlassHeader(
                  selectedIndex: _selectedIndex,
                  onTabSelected: _selectTab,
                  homeProvider: homeProvider,
                  authProvider: authProvider,
                  canDownload: downloads.isSupported,
                  tabNodes: _tabNodes,
                ),
              ),
            ),
          // Hidden over an open page: it would sit on top of its back button.
          if (!isWide && _selectedIndex != 0 && !_pageOpen)
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

    if (!isTv) return shell;

    // Sur un téléviseur, Retour sur l'écran principal ne ferme plus l'app du
    // premier coup : il remonte vers l'en-tête, puis vers l'accueil, puis
    // demande confirmation. Voir [_handleTvBack].
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleTvBack();
      },
      child: shell,
    );
  }
}

class _DesktopGlassHeader extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTabSelected;
  final HomeProvider homeProvider;
  final AuthProvider authProvider;

  /// Faux sur le web, où il n'y a pas d'espace de stockage applicatif : sans
  /// destination possible, l'onglet n'existe pas.
  final bool canDownload;

  /// Un nœud par onglet, possédés par la coquille.
  final List<FocusNode> tabNodes;

  const _DesktopGlassHeader({
    required this.selectedIndex,
    required this.onTabSelected,
    required this.homeProvider,
    required this.authProvider,
    required this.canDownload,
    required this.tabNodes,
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
              focusNode: tabNodes[0],
              onTap: () => onTabSelected(0),
            ),
            GlassNavTab(
              label: 'Films',
              selected: selectedIndex == 1,
              focusNode: tabNodes[1],
              onTap: () => onTabSelected(1),
            ),
            GlassNavTab(
              label: 'Séries',
              selected: selectedIndex == 2,
              focusNode: tabNodes[2],
              onTap: () => onTabSelected(2),
            ),
            // The whole request catalog sits behind request_media server-side,
            // so an account without it gets no entry point either.
            if (authProvider.permissions.requestMedia)
              GlassNavTab(
                label: 'Demandes',
                selected: selectedIndex == 3,
                focusNode: tabNodes[3],
                onTap: () => onTabSelected(3),
              ),
            if (canDownload)
              GlassNavTab(
                label: 'Téléchargements',
                selected: selectedIndex == 4,
                focusNode: tabNodes[4],
                onTap: () => onTabSelected(4),
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
  final bool canDownload;

  const _MobileBottomNav({
    required this.selectedIndex,
    required this.onTabSelected,
    required this.canRequestMedia,
    required this.canDownload,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter.grouped(
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
                  if (canDownload)
                    _BottomNavItem(
                      icon: Icons.download_rounded,
                      label: 'Hors ligne',
                      selected: selectedIndex == 4,
                      onTap: () => onTabSelected(4),
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



/// L'app quand le serveur n'a pas répondu au démarrage.
///
/// Pas une version dégradée de la coquille habituelle : une coquille à part,
/// qui n'a qu'un écran parce qu'il n'y a qu'une chose à faire. Elle disparaît
/// d'elle-même — [AuthProvider.reconnect] repasse la session en ligne dès que
/// le sondage de connectivité retrouve le serveur, et la coquille normale
/// reprend sa place.
class _OfflineShell extends StatelessWidget {
  final AuthProvider authProvider;

  const _OfflineShell({required this.authProvider});

  @override
  Widget build(BuildContext context) {
    final reachability = Provider.of<ServerReachability>(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Positioned.fill(child: DownloadsScreen()),
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
                    IconButton(
                      tooltip: 'Réessayer de joindre le serveur',
                      // Les deux, et pas seulement le sondage : si le serveur
                      // répondait déjà — l'authentification du démarrage a pu
                      // échouer sur un simple délai — il n'y aurait aucune
                      // transition à observer, et le bouton n'aurait rien fait.
                      onPressed: () async {
                        await reachability.check();
                        await authProvider.reconnect();
                      },
                      icon: const Icon(Icons.refresh_rounded,
                          color: AppColors.textSecondary),
                    ),
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
