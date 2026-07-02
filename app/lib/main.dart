import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'services/api_client.dart';
import 'providers/auth_provider.dart';
import 'providers/home_provider.dart';
import 'providers/library_provider.dart';
import 'providers/player_layout_provider.dart';
import 'services/layout_storage.dart';
import 'providers/search_provider.dart';
import 'navigation/search_route_observer.dart';
import 'screens/auth/login_screen.dart';
import 'screens/shell/main_shell.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'desktop_window.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: useHiddenNativeTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: Platform.isMacOS,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final apiClient = ApiClient();
  await apiClient.initialize();

  final searchRouteObserver = SearchRouteObserver();

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => HomeProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => PlayerLayoutProvider(LayoutStorage())),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
      ],
      child: PlayeurApp(searchRouteObserver: searchRouteObserver),
    ),
  );
}

class PlayeurApp extends StatelessWidget {
  final SearchRouteObserver searchRouteObserver;

  const PlayeurApp({super.key, required this.searchRouteObserver});

  @override
  Widget build(BuildContext context) {
    return SearchOverlayScope(
      routeObserver: searchRouteObserver,
      navigatorKey: rootNavigatorKey,
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        title: 'Playeur',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        navigatorObservers: [searchRouteObserver],
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
              return const LoginScreen();
            }
            return const MainShell();
          },
        ),
      ),
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
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.play_arrow_rounded, size: 44, color: Colors.white),
            ),
            const SizedBox(height: 28),
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 20),
            Text(
              'Connexion à Playeur…',
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
