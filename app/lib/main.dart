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
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'desktop_window.dart';

void main() async {
  // 1. Initialize Media Kit bindings (Crucial for MPV desktop/mobile loading)
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // 2. Initialize desktop window manager
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // 3. Instantiate persistent Api Client
  final apiClient = ApiClient();

  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider(create: (_) => AuthProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => HomeProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => PlayerLayoutProvider(LayoutStorage())),
      ],
      child: const PlayeurApp(),
    ),
  );
}

class PlayeurApp extends StatelessWidget {
  const PlayeurApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Playeur',
      debugShowCheckedModeBanner: false,

      // Gorgeous dark OLED/Cinematic theme
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141414),
        primaryColor: const Color(0xFF00A4DC), // Emby Blue
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00A4DC),
          secondary: Color(0xFF00A4DC),
          background: Color(0xFF141414),
          surface: Color(0xFF1F1F1F),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          elevation: 0,
        ),
        useMaterial3: true,
      ),

      builder: (context, child) {
        return Column(
          children: [
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
            Expanded(child: child!),
          ],
        );
      },

      // Reactive root router depending on authentication state
      home: Consumer<AuthProvider>(
        builder: (context, authProvider, _) {
          if (authProvider.isInitializing) {
            return const SplashScreen();
          }

          if (!authProvider.isAuthenticated) {
            return const LoginScreen();
          }

          return const HomeScreen();
        },
      ),
    );
  }
}

// Splash loading screen on app startup
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF141414),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.play_circle_fill,
              size: 72,
              color: Color(0xFF00A4DC),
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(
              color: Color(0xFF00A4DC),
            ),
            SizedBox(height: 16),
            Text(
              "Connexion à Playeur...",
              style: TextStyle(
                color: Colors.grey,
                fontSize: 16,
                letterSpacing: 1.2,
              ),
            )
          ],
        ),
      ),
    );
  }
}
