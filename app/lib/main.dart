import 'services/media_details_cache.dart';
import 'services/media_tracks_cache.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'utils/app_platform.dart';
import 'utils/mpv_native_view.dart';
import 'utils/window_controls.dart';
import 'services/api_client.dart';
import 'services/app_image_cache.dart';
import 'services/app_updater.dart';
import 'services/client_identity.dart';
import 'services/client_log.dart';
import 'services/auto_download.dart';
import 'services/download_manager.dart';
import 'services/downloads/download_keep_alive.dart';
import 'services/dns_warmup.dart';
import 'services/download_preferences.dart';
import 'services/network_status.dart';
import 'services/server_reachability.dart';
import 'providers/auth_provider.dart';
import 'providers/home_provider.dart';
import 'providers/library_provider.dart';
import 'providers/media_requests_provider.dart';
import 'providers/search_provider.dart';
import 'navigation/search_route_observer.dart';
import 'screens/shared_link/shared_link_app.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/server_choice_screen.dart';
import 'screens/auth/tv_login_screen.dart';
import 'tv/tv_focus.dart';
import 'tv/tv_focus_guard.dart';
import 'tv/tv_focus_scroll.dart';
import 'tv/tv_key_repeat.dart';
import 'tv/tv_mode.dart';
import 'tv/tv_pairing_link.dart';
import 'tv/tv_touchpad.dart';
import 'tv/tv_ui_scale.dart';
import 'screens/player/display_frame_rate.dart';
import 'screens/player/playback/adaptive_quality.dart';
import 'services/picture_in_picture.dart';
import 'screens/player/hardware_decoding.dart';
import 'screens/player/playback_profile.dart';
import 'services/playback_capabilities.dart';
import 'services/playback_preferences_storage.dart';
import 'screens/player/player_engine.dart';
import 'screens/shell/main_shell.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'desktop_window.dart';
import 'widgets/global/middle_click_autoscroll.dart';
import 'l10n/app_language.dart';
import 'l10n/tr.dart';

/// Les licences de ce qu'aucun paquet Dart ne déclare : les polices embarquées
/// — Manrope (OFL) et les icônes Phosphor (MIT) — et les moteurs de lecture
/// natifs, lues depuis le paquet.
///
/// Rendu paresseux : `LicenseRegistry` ne tire ce flux que si quelqu'un ouvre
/// la page des licences, donc les fichiers ne sont pas lus au démarrage.
Stream<LicenseEntry> _bundledFontLicenses() async* {
  final manrope = await rootBundle.loadString('assets/fonts/OFL.txt');
  yield LicenseEntryWithLineBreaks(const ['Manrope'], manrope);
  final phosphor =
      await rootBundle.loadString('assets/fonts/Phosphor-LICENSE.txt');
  yield LicenseEntryWithLineBreaks(const ['Phosphor Icons'], phosphor);
  // Les moteurs de lecture ne sont pas des paquets Dart : rien ne les déclare
  // à leur place, et la LGPL demande qu'ils soient nommés avec leurs sources.
  final players = await rootBundle.loadString('assets/legal/third_party.txt');
  yield LicenseEntryWithLineBreaks(
      const ['mpv, FFmpeg, AetherEngine, Media3'], players);
}

/// Enables trackpad / mouse drag scrolling on desktop (required on macOS).
class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  // Every scrollable passes through here, which is what lets the middle click
  // reach whichever of them sits under the mouse.
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return MiddleClickAutoScroll(
      details: details,
      child: super.buildScrollbar(context, child, details),
    );
  }
}

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// The mouse's back side button does what the system back does: close the
/// dialog, the player or the page on top.
///
/// Going through the root navigator is enough for pages opened under the nav
/// bar too: the shell's route refuses the pop while one is open, and hands it
/// to its own navigator — see `MainShell`. Not on the web, where the browser
/// already turns that button into its own history back.
void _handleMouseBackButton(PointerDownEvent event) {
  if (kIsWeb ||
      event.kind != PointerDeviceKind.mouse ||
      event.buttons & kBackMouseButton == 0) {
    return;
  }
  rootNavigatorKey.currentState?.maybePop();
}

Future<void> _configureSystemUi() async {
  // A television has no status bar and no navigation bar to blend into, and
  // asking for edge-to-edge there just adds insets nothing draws behind.
  if (!AppPlatform.isMobile || TvMode.isTv) return;

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Avant tout le reste : ce qui s'écrit pendant le démarrage — les capacités
  // de l'appareil, le profil de lecture retenu, une requête qui échoue — est
  // précisément ce qu'on vient chercher dans le journal quand l'app ne va pas
  // plus loin. Voir [ClientLog].
  ClientLog.install();
  // Pas sur les appareils Apple, qu'AetherEngine lit (ADR-0038) : charger
  // libmpv y mettrait un second FFmpeg dans le processus pour rien, et l'Apple
  // TV ne l'embarque même pas.
  if (!AppPlatform.isApple) {
    // Le libmpv patché qui sait dessiner dans une vue native, s'il est
    // installé et se charge. Sinon, celui que media_kit embarque.
    MpvNativeView.resolve();
    MediaKit.ensureInitialized(libmpv: MpvNativeView.libmpvPath);
  }

  // La licence de la police embarquée, que `google_fonts` déclarait pour nous
  // avant l'ADR-0025.
  LicenseRegistry.addLicense(_bundledFontLicenses);

  AppImageCache.configure();
  // A QR scanned on the TV opens this app with ?tv=CODE. Read it now, act on it
  // once the shell is up and there is a session to approve with.
  TvPairingLink.capture();
  // Observe les flèches maintenues, pour que le focus ne coure pas plus vite
  // que les rangées ne défilent. Voir [TvKeyRepeat].
  TvKeyRepeat.install();
  // Sur Apple TV, la force d'un glissé sur le trackpad accélère la navigation
  // et l'avance rapide. Voir [TvTouchpad].
  TvTouchpad.install();

  final apiClient = ApiClient();

  // Tout ce qui précède la première image, lancé ensemble.
  //
  // Chacune de ces initialisations est une question posée à la plateforme —
  // les préférences, la version du paquet, la fenêtre, le trousseau — et
  // aucune ne dépend de la réponse d'une autre. Enchaînées par `await`, leurs
  // allers-retours s'additionnaient devant l'écran de démarrage ; lancées
  // ensemble, c'est la plus lente qui donne le tempo. Seul le mode TV reste
  // devant : le profil de lecture a besoin de sa réponse.
  final independent = <Future<void>>[
    // The device's own name and app version, sent on every request.
    ClientIdentity.initialize(),
    // What this device can decode and play back, which the server is told on
    // every session so it can hand over the file itself instead of a
    // re-encoded, stereo-folded approximation of it. Asked once: it describes
    // the hardware.
    PlaybackCapabilitiesResolver.initialize(),
    HardwareDecoding.initialize(),
    DisplayFrameRate.initialize(),
    AdaptiveQualityPreference.initialize(),
    // Les réglages de lecture que le player consulte sans attendre — le saut
    // d'intro automatique — chargés une fois pour toutes.
    PlaybackPreferencesStorage.initialize(),
    // Ce que cet appareil rapatrie tout seul, et sur quel réseau il a le droit
    // de le faire. Lus une fois : le premier tour de file les consulte.
    DownloadPreferences.instance.initialize(),
    // Whether this device can carry on with the film in a corner of the home
    // screen. Asked once: the answer is a property of the hardware.
    PictureInPicture.initialize(),
    WindowControls.initializeDesktopWindow(
      hiddenTitleBar: useHiddenNativeTitleBar,
      showWindowButtons: AppPlatform.isMacOS,
    ),
    apiClient.initialize(),
  ];

  // Resolved before the first frame: the login screen the user lands on differs
  // entirely between a phone and a television, and flipping it after the fact
  // would show the password form for a beat on every TV boot.
  await TvMode.initialize();

  // La langue aussi se décide avant la première image : sans cela un
  // appareil en anglais afficherait un écran de connexion en français, puis
  // le verrait se retraduire.
  await AppLanguage.load();

  // How much memory playback may spend here. Resolved before the first frame
  // like the TV mode above, because it is read when a media opens and the
  // answer never changes for the life of the process.
  independent.add(PlaybackProfiles.initialize(isTv: TvMode.detected));
  independent.add(_configureSystemUi());

  await Future.wait(independent);

  // Un lien de partage public (/share#code) ouvre l'app en invité : la page du
  // lien et le lecteur, sans compte ni bibliothèque. Voir ADR-0037.
  final sharedCode = sharedLinkCode(Uri.base);
  if (sharedCode != null) {
    runSharedLinkApp(sharedCode);
    return;
  }

  // A scanned pairing link names its own server. Point the client at it before
  // anything else runs: the phone that scans may have been signed in to another
  // address, or to none, and the code only exists on the one the TV used.
  final scannedOrigin = TvPairingLink.origin;
  if (scannedOrigin != null && scannedOrigin != apiClient.baseUrl) {
    await apiClient.setConnection(scannedOrigin);
  }

  final searchRouteObserver = SearchRouteObserver();

  // L'installeur d'une mise à jour Windows ne peut pas effacer le dossier
  // temporaire d'où il a tourné : c'est l'app qu'il relance qui s'en charge.
  unawaited(AppUpdater.purgeStaleWorkDirs());

  // Les téléchargements se relisent depuis le disque, pas depuis le serveur :
  // c'est ce qui permet à l'app de savoir ce qu'elle possède avant même de
  // savoir si elle a du réseau. L'initialisation n'est pas attendue — un
  // manifeste ne retarde pas la première image.
  final downloads = DownloadManager.instance;
  unawaited(downloads.initialize(apiClient));
  // Écran éteint, Android gèle une app sans service de premier plan : le
  // service suit la file, et sa notification dit où elle en est (ADR-0040).
  if (AppPlatform.isAndroid) DownloadKeepAlive(downloads).start();

  final authProvider = AuthProvider(apiClient);
  final reachability = ServerReachability(apiClient);

  // Les réglages de lecture suivent le compte (ADR-0043) : dès qu'on sait qui
  // est connecté, et sur quel serveur, l'appareil s'aligne sur lui. La clé ne
  // change qu'avec le compte, donc les autres notifications ne coûtent rien.
  String? playbackPreferencesAccount;
  authProvider.addListener(() {
    final user = authProvider.currentUser;
    final account = authProvider.isAuthenticated && user != null
        ? '${apiClient.baseUrl}|${user.id}'
        : null;
    if (account == playbackPreferencesAccount) return;
    playbackPreferencesAccount = account;
    if (account == null) {
      PlaybackPreferencesStorage.unbindAccount();
    } else {
      unawaited(PlaybackPreferencesStorage.bindAccount(apiClient, account));
    }
  });

  // Le lecteur résout le nom du serveur au moment d'ouvrir le flux : ce nom
  // doit déjà être dans le cache DNS du système. Voir [DnsWarmup].
  final servers = apiClient.servers;
  void warmServerNames() => DnsWarmup.watch(servers.knownUrls);
  servers.addListener(warmServerNames);
  warmServerNames();

  // Sur quoi passent les octets. Une question distincte de celle que pose
  // [ServerReachability] : un NAS joignable en 4G est joignable, et rapatrier
  // une saison dessus vide un forfait.
  final network = NetworkStatus();
  final downloadPreferences = DownloadPreferences.instance;

  // Le seul endroit où le réseau et le réglage se croisent. Le magasin hors
  // ligne pose la question à chaque média de la file, sans rien savoir des deux.
  downloads.transferGate =
      () => !network.isMetered || downloadPreferences.allowsMeteredNow;

  final autoDownloads = AutoDownloadService(
    manager: downloads,
    api: apiClient,
    preferences: downloadPreferences,
    isOnline: () => reachability.isOnline,
  );
  autoDownloads.start();

  // Le retour d'un réseau libre est le rendez-vous de ce qui attendait : la
  // réserve prévue dans le métro descend en rentrant, sans rien rouvrir.
  network.addUnmeteredListener(() {
    downloads.onNetworkChanged();
    autoDownloads.refresh();
  });
  // Un changement de réseau dans l'autre sens compte aussi : passer en 4G au
  // milieu d'une saison doit arrêter la suite, pas la laisser filer.
  network.addListener(downloads.onNetworkChanged);
  unawaited(network.start());

  // Un même appareil peut tenir plusieurs serveurs (ADR-0013). Ce qui est en
  // mémoire appartient à celui qu'on quitte — identifiants de médias compris,
  // qui sont propres à un serveur — donc tout est vidé avant que l'autre
  // réponde. Le câblage est ici plutôt que dans [AuthProvider] : savoir qui est
  // connecté n'oblige pas à connaître la bibliothèque ni les téléchargements.
  final homeProvider = HomeProvider(apiClient);
  final libraryProvider = LibraryProvider(apiClient);
  final mediaRequestsProvider = MediaRequestsProvider(apiClient);
  authProvider.onServerChanged = () {
    MediaDetailsCache.clear();
    MediaTracksCache.clear();
    homeProvider.reset();
    libraryProvider.reset();
    mediaRequestsProvider.reset();
    unawaited(downloads.onServerChanged());
    // Les plans de réserve sont indexés par identifiant de série, et un
    // identifiant ne veut rien dire sur un autre serveur : on repart de zéro.
    autoDownloads.refresh();
  };

  // Les titres et synopsis viennent du serveur dans la langue de l'app
  // (ADR-0049) : en changer périme ce qui est en mémoire, comme un changement
  // de serveur. Les téléchargements, eux, gardent le texte du jour où ils ont
  // été faits.
  AppLanguage.notifier.addListener(() {
    if (!authProvider.isAuthenticated) return;
    MediaDetailsCache.clear();
    homeProvider.reset();
    libraryProvider.reset();
    mediaRequestsProvider.reset();
  });

  // Le retour du serveur est le seul moment qui compte pour les deux : la
  // session en cache redevient une vraie session, et ce qui a été regardé hors
  // ligne part enfin vers le serveur.
  reachability.addRestoredListener(() {
    unawaited(authProvider.reconnect());
    unawaited(downloads.onServerReachable());
    // Sans serveur il n'y a pas de « prochain épisode » à demander : ce qui n'a
    // pas pu être planifié hors ligne se planifie maintenant.
    autoDownloads.refresh();
    unawaited(network.refresh());
    // Une demande d'accès partie ailleurs a pu être acceptée pendant qu'on
    // était hors ligne : le serveur retrouvé est le bon moment pour aller
    // chercher le verdict.
    unawaited(authProvider.refreshAccessRequests());
    // Les liens de comptes vivent sur les serveurs (ADR-0017) : un lien fait
    // depuis un autre appareil apparaît ici au retour du réseau.
    unawaited(apiClient.refreshAccountLinks());
    // Un réglage changé hors ligne part maintenant, et ceux changés depuis un
    // autre appareil arrivent.
    unawaited(PlaybackPreferencesStorage.syncWithAccount());
  });
  reachability.start();
  unawaited(apiClient.refreshAccountLinks());

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider<DownloadManager>.value(value: downloads),
        ChangeNotifierProvider<DownloadPreferences>.value(
            value: downloadPreferences),
        ChangeNotifierProvider<NetworkStatus>.value(value: network),
        ChangeNotifierProvider<ServerReachability>.value(value: reachability),
        ChangeNotifierProvider<HomeProvider>.value(value: homeProvider),
        ChangeNotifierProvider<LibraryProvider>.value(value: libraryProvider),
        ChangeNotifierProvider<MediaRequestsProvider>.value(
            value: mediaRequestsProvider),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
      ],
      // Changer de langue reconstruit l'app entière : les textes sont lus par
      // `tr()` au moment du build, et rien d'autre ne dirait à un écran déjà
      // construit de se retraduire.
      child: ValueListenableBuilder<AppLanguage>(
        valueListenable: AppLanguage.notifier,
        builder: (context, language, _) => OnyxApp(
          key: ValueKey(language),
          searchRouteObserver: searchRouteObserver,
        ),
      ),
    ),
  );

  // Build the playback engine while the user is still browsing. Creating the
  // libmpv context and its video texture costs the same whether it happens here
  // or in front of a spinner the moment a media is launched — so it happens
  // here. Deferred past the first frame, and past the home screen's own load,
  // because the point is to use idle time, not to compete for it.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 3), PlayerEnginePool.prewarm);
    // Une demande d'accès approuvée pendant que l'app était fermée n'attend que
    // d'être relevée : le serveur garde la session prête pendant une semaine.
    unawaited(authProvider.refreshAccessRequests());
  });
}

class OnyxApp extends StatelessWidget {
  final SearchRouteObserver searchRouteObserver;

  const OnyxApp({super.key, required this.searchRouteObserver});

  @override
  Widget build(BuildContext context) {
    // One listener at the root republishes the mode through the tree, so a
    // toggle in the settings takes effect everywhere at once instead of on the
    // next cold start.
    return ValueListenableBuilder<bool>(
      valueListenable: TvMode.enabled,
      builder: (context, isTv, _) {
        return TvScope(
          isTv: isTv,
          // Le focus est le seul moyen d'agir avec une télécommande : s'il se
          // perd, l'app a l'air gelée. Voir [TvFocusGuard].
          child: TvFocusGuard(
            child: SearchOverlayScope(
              routeObserver: searchRouteObserver,
              navigatorKey: rootNavigatorKey,
              child: MaterialApp(
                navigatorKey: rootNavigatorKey,
                title: 'Onyx',
                debugShowCheckedModeBanner: false,
                // Sur un téléviseur, chaque page est mise en page sur une
                // largeur fixe puis mise à l'échelle de l'écran, pour que l'app
                // ait la même taille quelle que soit la densité annoncée —
                // voir [TvUiScale]. Le lecteur n'est pas concerné.
                theme: isTv
                    ? AppTheme.dark.copyWith(
                        pageTransitionsTheme: PageTransitionsTheme(
                          builders: <TargetPlatform, PageTransitionsBuilder>{
                            for (final platform in TargetPlatform.values)
                              platform: const TvScaledPageTransitionsBuilder(),
                          },
                        ),
                      )
                    : AppTheme.dark,
                scrollBehavior: AppScrollBehavior(),
                navigatorObservers: [searchRouteObserver],
                // The D-pad's centre button and a controller's A, folded into the
                // bindings Flutter already has for Enter. Everything that was
                // keyboard-activatable becomes remote-activatable, app-wide,
                // without a single widget knowing about it.
                shortcuts: <ShortcutActivator, Intent>{
                  ...WidgetsApp.defaultShortcuts,
                  ...tvSelectShortcuts,
                },
                // Les flèches maintenues sont régulées, sans quoi le focus
                // dépasse les cartes qu'une rangée n'a pas encore construites.
                actions: <Type, Action<Intent>>{
                  ...WidgetsApp.defaultActions,
                  DirectionalFocusIntent: TvDirectionalFocusAction(),
                  // Retour à la télécommande hors Android — voir [TvBackAction].
                  TvBackIntent: TvBackAction(),
                },
                builder: (context, child) {
                  // Au-dessus du Navigator, qui hérite de cette politique : un
                  // seul défilement par pas de télécommande, animé, au lieu
                  // d'un saut suivi d'une animation. Voir [TvFocusScroll].
                  return FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(
                      requestFocusCallback: TvFocusScroll.requestFocus,
                    ),
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _handleMouseBackButton,
                      child: Column(
                        children: [
                          if (useDesktopCaptionBar)
                            ValueListenableBuilder<bool>(
                              valueListenable: showDesktopCaption,
                              builder: (context, visible, _) {
                                return Visibility(
                                  visible: visible,
                                  maintainState: false,
                                  child: const WindowCaptionBar(),
                                );
                              },
                            ),
                          Expanded(
                            child: ColoredBox(
                              color: AppColors.background,
                              child: child ?? const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                home: Consumer<AuthProvider>(
                  builder: (context, authProvider, _) {
                    if (authProvider.isInitializing) {
                      return const SplashScreen();
                    }
                    // Le serveur principal n'a pas répondu et il y a un
                    // ailleurs : l'app demande où aller plutôt que de se
                    // rabattre en silence sur le cache.
                    if (authProvider.needsServerChoice) {
                      return const ServerChoiceScreen();
                    }
                    if (!authProvider.isAuthenticated) {
                      // A television gets the QR pairing instead of a password
                      // form. The form is still reachable from it, for the first
                      // account on a server and for anyone without a phone.
                      return isTv ? const TvLoginScreen() : const LoginScreen();
                    }
                    return const MainShell();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.textPrimary.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 44,
                color: AppColors.background,
              ),
            ),
            const SizedBox(height: 28),
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 20),
            Text(
              tr('Connexion à Onyx…'),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.5,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
