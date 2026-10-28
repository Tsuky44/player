import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/app_download.dart';
import '../../models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/watch_lists_provider.dart';
import '../../services/api_client.dart';
import '../../services/auto_updater_service.dart';
import '../../services/download_manager.dart';
import '../../services/interface_tour_storage.dart';
import '../../services/server_reachability.dart';
import '../../services/update_checker.dart';
import '../../theme/app_colors.dart';
import '../../utils/responsive.dart';
import '../../widgets/global/account_menu.dart';
import '../../widgets/global/announcement_dialog.dart';
import '../../widgets/global/app_update_dialog.dart';
import '../../widgets/global/interface_tour/interface_tour.dart';
import '../../widgets/global/interface_tour/tour_anchor.dart';
import '../../desktop_window.dart';
import '../../navigation/media_link.dart';
import '../../navigation/shell_navigator.dart';
import '../../tv/tv_deferred_keyboard.dart';
import '../../tv/tv_mode.dart';
import '../../tv/tv_pairing_link.dart';
import '../settings/tv_pairing_screen.dart';
import '../downloads/downloads_screen.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../requests/requests_screen.dart';
import '../lists/lists_screen.dart';
import 'mobile_bottom_nav.dart';
import 'mobile_top_bar.dart';
import 'pending_announcement.dart';
import 'shell_desktop_header.dart';
import 'shell_page_open_listener.dart';
import 'shell_tab_stack.dart';
import 'shell_tabs.dart';
import '../../theme/app_icons.dart';
import '../../l10n/tr.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  /// L'onglet affiché, par identifiant (voir [ShellTabs]) : les bibliothèques
  /// sont celles du serveur, et leur nombre change.
  String _selectedTab = ShellTabs.home;

  /// Un nœud par onglet de l'en-tête, pour que Retour puisse y ramener la
  /// télécommande. Créés à la demande, sous l'identifiant de l'onglet.
  final Map<String, FocusNode> _tabNodes = {};

  FocusNode _tabNode(String tab) => _tabNodes.putIfAbsent(
      tab, () => FocusNode(debugLabel: 'nav-tab-$tab'));

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

  /// Les onglets réellement montés dans [ShellTabStack].
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
  final Set<String> _mountedTabs = {ShellTabs.home};

  /// Vrai une fois l'accueil posé : tous les onglets se montent alors, y
  /// compris ceux des bibliothèques ajoutées ensuite.
  bool _allTabsWarm = false;
  Timer? _warmTimer;

  /// Checks the server for a newer build in the background and drives the
  /// update dialog on its own — the header button stays as a manual fallback,
  /// but nobody needs to notice or click it for the app to catch up.
  AutoUpdateService? _autoUpdate;
  bool _updateDialogOpen = false;

  /// Monte les autres onglets une fois l'accueil passé.
  ///
  /// Le délai est celui de [PlayerEnginePool.prewarm], et pour la même raison :
  /// le but est d'occuper un moment creux, pas de disputer le démarrage à ce
  /// que l'utilisateur regarde.
  static const Duration _warmDelay = Duration(seconds: 3);

  void _warmOtherTabs() {
    if (_allTabsWarm) return;
    setState(() => _allTabsWarm = true);
  }

  /// Les zones du chrome que la présentation de l'interface montre.
  final TourAnchors _tourAnchors = TourAnchors();

  /// Le compte pour lequel la question « a-t-il vu la présentation ? » a déjà
  /// été posée, pour ne la reposer qu'à un changement de compte.
  String? _tourCheckedFor;
  bool _tourOpen = false;
  late final AuthProvider _auth = context.read<AuthProvider>();

  /// Joue la présentation de l'interface à la première session d'un compte sur
  /// cet appareil.
  ///
  /// Seulement sur l'accueil nu : par-dessus une fiche, une mise à jour ou
  /// l'approbation d'un téléviseur, elle décrirait un écran qu'on ne voit pas.
  /// Ce n'est que partie remise — rien n'est noté tant qu'elle n'a pas été
  /// montrée, et elle revient au lancement suivant.
  Future<void> _maybeStartTour() async {
    final accountId = _auth.activeServer?.id;
    if (accountId == null || accountId == _tourCheckedFor) return;
    if (_auth.isOfflineSession || _tourOpen) return;
    _tourCheckedFor = accountId;
    if (await InterfaceTourStorage.hasSeen(accountId)) return;
    if (mounted) await _playTour(onlyOnBareHome: true);
  }

  /// « Revoir la présentation », depuis les réglages : eux se sont déjà
  /// refermés, il reste à revenir sur l'accueil.
  void _onTourReplayRequested() {
    if (_auth.isOfflineSession) return;
    _selectTab(ShellTabs.home);
    unawaited(_playTour());
  }

  Future<void> _playTour({bool onlyOnBareHome = false}) async {
    if (_tourOpen) return;
    _tourOpen = true;
    try {
      // Le bandeau et les rangées font partie de ce qu'on montre : tant que
      // l'accueil charge, ils n'existent pas.
      await _homeSettled();
      if (!mounted) return;
      if (onlyOnBareHome) {
        if (_selectedTab != ShellTabs.home || _pageOpen || _updateDialogOpen) {
          return;
        }
        if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      }
      final accountId = _auth.activeServer?.id;
      await showInterfaceTour(context, anchors: _tourAnchors);
      if (accountId != null) await InterfaceTourStorage.markSeen(accountId);
    } finally {
      _tourOpen = false;
    }
  }

  /// Le message de l'administrateur (ADR-0069), posé sur l'accueil une fois
  /// chargé, comme la présentation.
  late final PendingAnnouncementCheck _announcement = PendingAnnouncementCheck(
    fetch: () => context.read<ApiClient>().getPendingAnnouncement(),
    markSeen: (id) => context.read<ApiClient>().markAnnouncementSeen(id),
    show: (announcement) async {
      await _homeSettled();
      if (!mounted) return false;
      await showAnnouncementDialog(context, announcement);
      return true;
    },
  );

  /// Un compte vient de s'ouvrir : la présentation d'abord s'il ne l'a jamais
  /// vue, puis le message de l'administrateur — l'un après l'autre, jamais
  /// l'un sur l'autre.
  Future<void> _afterSessionOpened() async {
    await _maybeStartTour();
    if (!mounted || _auth.isOfflineSession) return;
    await _announcement.run(_auth.activeServer?.id);
  }

  /// Rend la main quand l'accueil a fini de charger — sur ses données ou sur
  /// une erreur — et que son contenu est posé à l'écran.
  Future<void> _homeSettled() async {
    final home = context.read<HomeProvider>();
    bool pending() =>
        home.isLoading || (home.homeData == null && home.errorMessage == null);
    if (pending()) {
      final settled = Completer<void>();
      void check() {
        if (!mounted || !pending()) settled.complete();
      }

      home.addListener(check);
      await settled.future;
      home.removeListener(check);
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  /// Un autre compte vient de s'ouvrir sans que la coquille soit remontée —
  /// une bascule de serveur : c'est une première session comme une autre.
  void _onAuthChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_afterSessionOpened());
    });
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    InterfaceTourReplay.requests.removeListener(_onTourReplayRequested);
    _warmTimer?.cancel();
    _autoUpdate?.dispose();
    for (final node in _tabNodes.values) {
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
      // Les onglets sont les bibliothèques du serveur : sans cette liste la
      // coquille n'a que l'accueil.
      unawaited(context.read<LibraryProvider>().loadLibraries());
      // L'onglet des listes n'existe que si le serveur sait en tenir.
      unawaited(context.read<WatchListsProvider>().load());
      _warmTimer = Timer(_warmDelay, () {
        if (mounted) _warmOtherTabs();
      });
      final code = TvPairingLink.take();
      if (code == null) {
        unawaited(_afterSessionOpened());
        // « Lire dans Onyx » depuis OnyxHub : la fiche s'ouvre par-dessus les onglets.
        final linked = MediaLink.takeRoute();
        if (linked != null) unawaited(shellNavigatorKey.currentState?.push(linked));
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TvPairingScreen(initialCode: code)),
      );
    });
    _auth.addListener(_onAuthChanged);
    InterfaceTourReplay.requests.addListener(_onTourReplayRequested);
    final api = context.read<ApiClient>();
    _autoUpdate = AutoUpdateService(
      findUpdate: () => UpdateChecker.findAvailableUpdate(api),
      onUpdateFound: _handleUpdateFound,
    )..start();
  }

  /// Opens the update dialog on its own once the server turns out to have a
  /// newer build — [showAppUpdateDialog]'s `autoStart` then chains straight
  /// through download, install and a countdown to restart.
  void _handleUpdateFound(AppDownload download) {
    if (!mounted || _updateDialogOpen) return;
    _updateDialogOpen = true;
    showAppUpdateDialog(context, download: download, autoStart: true)
        .whenComplete(() => _updateDialogOpen = false);
  }

  /// Vrai quand une page (fiche d'un média, d'une personne…) est ouverte
  /// par-dessus les onglets, dans [shellNavigatorKey].
  bool _pageOpen = false;

  void _selectTab(String tab) {
    // Un onglet choisi depuis une fiche ramène aux onglets, y compris celui
    // qui était déjà sélectionné : c'est le chemin du retour à la liste.
    if (_pageOpen) {
      shellNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    if (_selectedTab == tab) return;
    // Un onglet choisi avant son tour se monte maintenant : l'attente d'une
    // image vaut mieux que celle de la fin du délai.
    setState(() {
      _mountedTabs.add(tab);
      _selectedTab = tab;
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
    if (!isWide) {
      // Une fiche ouverte sur téléphone n'a pas de barre de verre : son
      // contenu défile sous l'heure et les icônes de la barre d'état et se
      // superpose à eux. Un voile sombre court les garde lisibles. La pile
      // reste en place quand la fiche se ferme, pour ne pas déplacer le
      // navigateur dans l'arbre.
      navigator = Stack(
        fit: StackFit.passthrough,
        children: [
          navigator,
          if (_pageOpen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: media.padding.top + 12,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.background.withValues(alpha: 0.85),
                        AppColors.background.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return NavigatorPopHandler<Object?>(
      // Retour (Android, souris, clavier) ferme d'abord la fiche ouverte.
      onPopWithResult: (_) => shellNavigatorKey.currentState?.maybePop(),
      child: ShellPageOpenListener(
        navigatorKey: shellNavigatorKey,
        pageOpen: _pageOpen,
        onPageOpenChanged: (open) => setState(() => _pageOpen = open),
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
    // Le champ de recherche gardait le focus clavier fermé : Retour proposait
    // de quitter l'app au lieu de rendre la télécommande à la barre.
    if (TvDeferredKeyboardState.releaseFocused()) return;
    if (!_headerNode.hasFocus) {
      _focusTab(_selectedTab);
      return;
    }
    if (_selectedTab != ShellTabs.home) {
      _selectTab(ShellTabs.home);
      _focusTab(ShellTabs.home);
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
      ..showSnackBar(SnackBar(
        content: Text(tr('Appuyez de nouveau sur Retour pour quitter')),
        duration: _exitWindow,
      ));
  }

  /// Les onglets dont la liste a quitté son haut : la barre du haut mobile y
  /// prend son verre ([MobileTopBar]).
  final Set<String> _scrolledTabs = {};

  Widget _trackScroll(String tab, Widget child) {
    return ScrollEdgeListener(
      onScrolledChanged: (scrolled) => setState(() {
        scrolled ? _scrolledTabs.add(tab) : _scrolledTabs.remove(tab);
      }),
      child: child,
    );
  }

  /// Haut depuis le contenu arrive sur l'onglet affiché, comme sur Android TV.
  ///
  /// Le parcours directionnel choisissait l'onglet le plus proche à la
  /// verticale : depuis le bouton du bandeau on montait sur « Films » en étant
  /// sur l'accueil, et l'on ne savait plus quel onglet était ouvert. La
  /// recherche et le compte, à droite, restent atteignables tels quels.
  void _landOnSelectedTab(String selectedTab) {
    final landed = FocusManager.instance.primaryFocus;
    final selected = _tabNodes[selectedTab];
    if (landed == null || selected == null || identical(landed, selected)) {
      return;
    }
    if (!_tabNodes.values.contains(landed) || selected.context == null) return;
    selected.requestFocus();
  }

  void _focusTab(String tab) {
    // Un onglet absent de l'en-tête (pas de droit de demande, pas de
    // téléchargements sur cet appareil, bibliothèque retirée) n'a pas de nœud
    // monté : l'accueil, lui, est toujours là.
    final node = _tabNode(tab);
    (node.context != null ? node : _tabNode(ShellTabs.home)).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // L'en-tête et la barre d'onglets sont deux verres posés sur la même
    // page, l'un en haut l'autre en bas : ils lisent la même image et n'ont
    // donc besoin de la lire qu'une fois. Voir l'ADR-0025. Ce qui vient en
    // surimpression — le menu de compte, la recherche du catalogue — n'entre
    // pas dans le groupe : il couvre le chrome et doit le flouter.
    return TourAnchorScope(
      anchors: _tourAnchors,
      child: BackdropGroup(child: _buildShell(context)),
    );
  }

  Widget _buildShell(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    final downloads = Provider.of<DownloadManager>(context);
    final canUseLists = Provider.of<WatchListsProvider>(context).isSupported;

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

    final libraryProvider = Provider.of<LibraryProvider>(context);
    final libraries = libraryProvider.libraries;
    VoidCallback? openFirst(LibraryKind kind) {
      final library = libraryProvider.firstLibraryOf(kind);
      return library == null
          ? null
          : () => _selectTab(ShellTabs.library(library));
    }

    final tabWidgets = <String, Widget>{
      ShellTabs.home: _trackScroll(
        ShellTabs.home,
        HomeScreen(
          embedded: isWide,
          onNavigateToMovies: openFirst(LibraryKind.movies),
          onNavigateToShows: openFirst(LibraryKind.shows),
          onOpenLibrary: (libraryId) {
            for (final library in libraries) {
              if (library.id == libraryId) {
                _selectTab(ShellTabs.library(library));
              }
            }
          },
        ),
      ),
      for (final library in libraries)
        ShellTabs.library(library): _trackScroll(
          ShellTabs.library(library),
          LibraryScreen(library: library, embedded: isWide),
        ),
      ShellTabs.requests:
          _trackScroll(ShellTabs.requests, RequestsScreen(embedded: isWide)),
      if (canUseLists)
        ShellTabs.lists:
            _trackScroll(ShellTabs.lists, ListsScreen(embedded: isWide)),
      ShellTabs.downloads:
          _trackScroll(ShellTabs.downloads, DownloadsScreen(embedded: isWide)),
    };
    // Une bibliothèque retirée pendant qu'on la regardait (supprimée, ou
    // serveur changé) rend la main à l'accueil.
    final selectedTab =
        tabWidgets.containsKey(_selectedTab) ? _selectedTab : ShellTabs.home;
    final tabs = ShellTabStack(
      selected: selectedTab,
      mounted: _allTabsWarm ? tabWidgets.keys.toSet() : _mountedTabs,
      tabs: tabWidgets,
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
                      : _buildPageNavigator(context,
                          tabs: tabs, isWide: isWide),
                ),
                if (!isWide)
                  MobileBottomNav(
                    selected: selectedTab,
                    onTabSelected: _selectTab,
                    libraries: libraries,
                    canRequestMedia: authProvider.permissions.requestMedia,
                    canDownload: downloads.isSupported,
                    canUseLists: canUseLists,
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
                onFocusChange: (focused) {
                  if (focused && isTv) _landOnSelectedTab(selectedTab);
                },
                child: ShellDesktopHeader(
                  selected: selectedTab,
                  onTabSelected: _selectTab,
                  libraries: libraries,
                  homeProvider: homeProvider,
                  authProvider: authProvider,
                  canDownload: downloads.isSupported,
                  canUseLists: canUseLists,
                  nodeFor: _tabNode,
                ),
              ),
            ),
          // Hidden over an open page: it would sit on top of its back button.
          if (!isWide && !_pageOpen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MobileTopBar(
                scrolled: _scrolledTabs.contains(selectedTab),
                authProvider: authProvider,
                homeProvider: homeProvider,
                onLogoTap: () => _selectTab(ShellTabs.home),
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
                      tooltip: tr('Réessayer de joindre le serveur'),
                      // Les deux, et pas seulement le sondage : si le serveur
                      // répondait déjà — l'authentification du démarrage a pu
                      // échouer sur un simple délai — il n'y aurait aucune
                      // transition à observer, et le bouton n'aurait rien fait.
                      onPressed: () async {
                        await reachability.check();
                        await authProvider.reconnect();
                      },
                      icon: const Icon(AppIcons.refresh,
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
