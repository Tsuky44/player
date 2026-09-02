import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'utils/app_platform.dart';
import 'utils/window_controls.dart';
import 'services/api_client.dart';
import 'services/app_image_cache.dart';
import 'providers/auth_provider.dart';
import 'providers/home_provider.dart';
import 'providers/library_provider.dart';
import 'providers/media_requests_provider.dart';
import 'providers/player_layout_provider.dart';
import 'services/layout_storage.dart';
import 'providers/search_provider.dart';
import 'navigation/search_route_observer.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/tv_login_screen.dart';
import 'tv/tv_focus.dart';
import 'tv/tv_focus_guard.dart';
import 'tv/tv_mode.dart';
import 'tv/tv_pairing_link.dart';
import 'screens/player/display_frame_rate.dart';
import 'screens/player/hardware_decoding.dart';
import 'screens/player/playback_profile.dart';
import 'screens/player/player_engine.dart';
import 'screens/shell/main_shell.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'desktop_window.dart';

/// Enables trackpad / mouse drag scrolling on desktop (required on macOS).
class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
  MediaKit.ensureInitialized();

  // Resolved before the first frame: the login screen the user lands on differs
  // entirely between a phone and a television, and flipping it after the fact
  // would show the password form for a beat on every TV boot.
  await TvMode.initialize();

  // How much memory playback may spend here. Resolved before the first frame
  // like the TV mode above, because it is read when a media opens and the
  // answer never changes for the life of the process.
  await PlaybackProfiles.initialize(isTv: TvMode.detected);
  await HardwareDecoding.initialize();
  await DisplayFrameRate.initialize();

  // A QR scanned on the TV opens this app with ?tv=CODE. Read it now, act on it
  // once the shell is up and there is a session to approve with.
  TvPairingLink.capture();

  await _configureSystemUi();

  await WindowControls.initializeDesktopWindow(
    hiddenTitleBar: useHiddenNativeTitleBar,
    showWindowButtons: AppPlatform.isMacOS,
  );

  AppImageCache.configure();

  final apiClient = ApiClient();
  await apiClient.initialize();

  // A scanned pairing link names its own server. Point the client at it before
  // anything else runs: the phone that scans may have been signed in to another
  // address, or to none, and the code only exists on the one the TV used.
  final scannedOrigin = TvPairingLink.origin;
  if (scannedOrigin != null && scannedOrigin != apiClient.baseUrl) {
    await apiClient.setConnection(scannedOrigin);
  }

  final searchRouteObserver = SearchRouteObserver();

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => HomeProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => MediaRequestsProvider(apiClient)),
        ChangeNotifierProxyProvider<AuthProvider, PlayerLayoutProvider>(
          create: (_) => PlayerLayoutProvider(LayoutStorage(), apiClient),
          update: (_, auth, previous) {
            final provider =
                previous ?? PlayerLayoutProvider(LayoutStorage(), apiClient);
            provider.onAuthChanged(auth);
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
      ],
      child: OnyxApp(searchRouteObserver: searchRouteObserver),
    ),
  );

  // Build the playback engine while the user is still browsing. Creating the
  // libmpv context and its video texture costs the same whether it happens here
  // or in front of a spinner the moment a media is launched — so it happens
  // here. Deferred past the first frame, and past the home screen's own load,
  // because the point is to use idle time, not to compete for it.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(seconds: 3), PlayerEnginePool.prewarm);
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
                theme: AppTheme.dark,
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
                builder: (context, child) {
                  return Column(
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
                  );
                },
                home: Consumer<AuthProvider>(
                  builder: (context, authProvider, _) {
                    if (authProvider.isInitializing) {
                      return const SplashScreen();
                    }
                    if (!authProvider.isAuthenticated) {
                      // A television gets the QR pairing instead of a password
                      // form. The form is still reachable from it, for the first
                      // account on a server and for anyone without a phone.
                      return isTv
                          ? const TvLoginScreen()
                          : const LoginScreen();
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
              'Connexion à Onyx…',
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
