import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/player_layout.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_layout_provider.dart';
import '../../services/api_client.dart';
import '../../services/download_manager.dart';
import '../../services/server_reachability.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../tv/tv_mode.dart';
import '../../utils/app_platform.dart';
import 'shared_link_screen.dart';

/// Le code du lien de partage que cette page ouvre, ou nul si elle n'en ouvre
/// aucun (ADR-0037).
///
/// Uniquement sur le web, à l'adresse `/share#code`. Le code est dans le
/// fragment, que le navigateur n'envoie jamais au serveur ; il revient vide
/// quand l'adresse a été tronquée, et la page le dit.
String? sharedLinkCode(Uri base) =>
    AppPlatform.isWeb ? parseSharedLinkCode(base) : null;

/// [sharedLinkCode] sans la condition du web, pour les tests.
@visibleForTesting
String? parseSharedLinkCode(Uri base) {
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  if (path != '/share') return null;
  var code = base.fragment.trim();
  while (code.startsWith('/')) {
    code = code.substring(1);
  }
  return code;
}

/// Démarre l'app en invité, pour le seul lien [code] : pas de compte, pas de
/// bibliothèque, seulement la page du lien et le lecteur Onyx.
///
/// Les fournisseurs sont ceux que le lecteur consulte, montés sur un
/// [SharedLinkApiClient] : ils ne voient aucun compte, même si ce navigateur
/// est connecté par ailleurs à ce serveur.
void runSharedLinkApp(String code) {
  final api = SharedLinkApiClient(code);
  final auth = AuthProvider(api);
  runApp(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
        ChangeNotifierProvider(create: (_) => ServerReachability(api)),
        ChangeNotifierProvider(create: (_) => HomeProvider(api)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(api)),
        // Toujours le Chrome Onyx, le playeur maison : pas celui qu'un compte
        // connecté dans ce navigateur aurait choisi.
        ChangeNotifierProvider(
            create: (_) => PlayerLayoutProvider.fixed(FixedChromeId.onyx, api)),
      ],
      child: SharedLinkApp(api: api),
    ),
  );
}

class SharedLinkApp extends StatelessWidget {
  const SharedLinkApp({super.key, required this.api});

  final SharedLinkApiClient api;

  Route<void> _page(String? name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => SharedLinkScreen(api: api),
      );

  @override
  Widget build(BuildContext context) {
    return TvScope(
      isTv: false,
      child: MaterialApp(
        title: 'Onyx',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        color: AppColors.background,
        // La page porte le nom de la route que le navigateur a donnée — le
        // code du lien. Sous le nom « / » habituel, Flutter réécrirait
        // l'adresse en /share#/ et un rechargement perdrait le lien.
        initialRoute:
            WidgetsBinding.instance.platformDispatcher.defaultRouteName,
        onGenerateInitialRoutes: (name) => [_page(name)],
        onGenerateRoute: (settings) => _page(settings.name),
      ),
    );
  }
}
