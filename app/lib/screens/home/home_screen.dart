import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/home_provider.dart';
import '../../models/models.dart';
import '../../widgets/global/media_card.dart';
import '../library/movies_screen.dart';
import '../library/shows_screen.dart';
import '../library/seasons_screen.dart';
import '../player/player_screen.dart';
import '../player_studio/player_studio_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<HomeProvider>(context, listen: false).loadHome();
    });
  }

  @override
  Widget build(BuildContext context) {
    final homeProvider = Provider.of<HomeProvider>(context);
    final authProvider = Provider.of<AuthProvider>(context);
    final brandColor = const Color(0xFF00A4DC);

    return Scaffold(
      backgroundColor: const Color(0xFF141414), // Cinematic Background
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.play_circle_fill, color: brandColor, size: 28),
            const SizedBox(width: 8),
            const Text(
              "PLAYEUR",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          // Indexer Scan Button / Indicator
          if (homeProvider.isScanning)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF00A4DC),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    "Scan...",
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            )
          else
            IconButton(
              tooltip: "Scanner la bibliothèque",
              icon: const Icon(Icons.sync, color: Colors.white),
              onPressed: () {
                homeProvider.triggerLibraryScan();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Scan de la bibliothèque lancé en arrière-plan..."),
                    backgroundColor: Colors.blue,
                  ),
                );
              },
            ),

          // Player Studio (customize controls layout)
          IconButton(
            tooltip: "Player Studio",
            icon: const Icon(Icons.tune, color: Colors.white),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayerStudioScreen()),
              );
            },
          ),

          // Logout Button
          IconButton(
            tooltip: "Se déconnecter",
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () {
              authProvider.logout();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => homeProvider.loadHome(),
        color: brandColor,
        backgroundColor: const Color(0xFF1F1F1F),
        child: homeProvider.isLoading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF00A4DC)),
              )
            : homeProvider.errorMessage != null
                ? _buildErrorView(homeProvider.errorMessage!)
                : SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Navigation Category Shortcuts
                        _buildCategoryShortcuts(),
                        const SizedBox(height: 32),

                        // 2. Continue Watching ("Reprendre la lecture")
                        if (homeProvider.homeData != null &&
                            homeProvider.homeData!.continueWatching.isNotEmpty) ...[
                          _buildSectionHeader("Reprendre la lecture", Icons.history),
                          const SizedBox(height: 12),
                          _buildContinueWatchingList(homeProvider.homeData!.continueWatching),
                          const SizedBox(height: 32),
                        ],

                        // 3. Recent Movies ("Films récents")
                        if (homeProvider.homeData != null &&
                            homeProvider.homeData!.recentMovies.isNotEmpty) ...[
                          _buildSectionHeader("Films récents", Icons.movie_outlined),
                          const SizedBox(height: 12),
                          _buildMediaHorizontalList(homeProvider.homeData!.recentMovies),
                          const SizedBox(height: 32),
                        ],

                        // 4. Recent TV Shows ("Séries récentes")
                        if (homeProvider.homeData != null &&
                            homeProvider.homeData!.recentShows.isNotEmpty) ...[
                          _buildSectionHeader("Séries récentes", Icons.tv),
                          const SizedBox(height: 12),
                          _buildMediaHorizontalList(homeProvider.homeData!.recentShows),
                        ],

                        // Empty State fallback
                        if (homeProvider.homeData == null ||
                            (homeProvider.homeData!.continueWatching.isEmpty &&
                                homeProvider.homeData!.recentMovies.isEmpty &&
                                homeProvider.homeData!.recentShows.isEmpty))
                          _buildEmptyStateView(),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildCategoryShortcuts() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Films Button
          Expanded(
            child: _buildShortcutCard(
              title: "FILMS",
              icon: Icons.movie_filter_rounded,
              color: const Color(0xFFE50914), // Elegant Red
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MoviesScreen()),
                );
              },
            ),
          ),
          const SizedBox(width: 16),
          // Séries Button
          Expanded(
            child: _buildShortcutCard(
              title: "SÉRIES",
              icon: Icons.tv_rounded,
              color: const Color(0xFF00A4DC), // Emby Blue
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ShowsScreen()),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutCard({
    required String title,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F1F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          children: [
            Icon(icon, size: 36, color: color),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF00A4DC), size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 18,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContinueWatchingList(List<HomeMediaItem> items) {
    return SizedBox(
      height: 250,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return Padding(
            padding: const EdgeInsets.only(right: 14),
            child: MediaCard(
              media: item.media,
              progress: item.percentWatched,
              onTap: () {
                // Click on in-progress media: launch player directly!
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PlayerScreen(media: item.media),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildMediaHorizontalList(List<Media> items) {
    return SizedBox(
      height: 250,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return Padding(
            padding: const EdgeInsets.only(right: 14),
            child: MediaCard(
              media: item,
              onTap: () {
                if (item.type == MediaType.movie) {
                  // Direct play movie
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlayerScreen(media: item),
                    ),
                  );
                } else if (item.type == MediaType.show) {
                  // Open TV series seasons list
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SeasonsScreen(show: item),
                    ),
                  );
                }
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildErrorView(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Provider.of<HomeProvider>(context, listen: false).loadHome();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A4DC),
              ),
              child: const Text("RÉESSAYER"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
        child: Column(
          children: [
            const Icon(Icons.movie_filter_outlined, size: 80, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              "Bibliothèque Vide",
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Ajoutez des fichiers vidéos dans vos répertoires Docker /media/Films ou /media/Series, puis cliquez sur le bouton Synchroniser en haut à droite.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Provider.of<HomeProvider>(context, listen: false).triggerLibraryScan();
              },
              icon: const Icon(Icons.sync),
              label: const Text("LANCER LA SYNCHRONISATION"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A4DC),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
