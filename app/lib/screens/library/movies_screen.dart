import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../widgets/global/media_card.dart';
import '../player/player_screen.dart';

class MoviesScreen extends StatefulWidget {
  const MoviesScreen({super.key});

  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LibraryProvider>(context, listen: false).loadMovies();
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = Provider.of<LibraryProvider>(context);
    final brandColor = const Color(0xFF00A4DC);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        title: const Text(
          "Tous les Films",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: libraryProvider.isLoadingMovies
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A4DC)),
            )
          : libraryProvider.errorMessage != null
              ? _buildErrorView(libraryProvider.errorMessage!)
              : libraryProvider.movies.isEmpty
                  ? _buildEmptyStateView()
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 140,
                        mainAxisExtent: 250,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: libraryProvider.movies.length,
                      itemBuilder: (context, index) {
                        final item = libraryProvider.movies[index];
                        return MediaCard(
                          media: item.media,
                          progress: item.percentWatched,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PlayerScreen(media: item.media),
                              ),
                            );
                          },
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
                Provider.of<LibraryProvider>(context, listen: false).loadMovies();
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A4DC)),
              child: const Text("RÉESSAYER"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.movie_creation_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              "Aucun film indexé",
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "Vérifiez que votre dossier Docker /media/Films contient des fichiers vidéos puis synchronisez depuis la page d'accueil.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
