import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../widgets/global/media_card.dart';
import 'seasons_screen.dart';

class ShowsScreen extends StatefulWidget {
  const ShowsScreen({super.key});

  @override
  State<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends State<ShowsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LibraryProvider>(context, listen: false).loadShows();
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraryProvider = Provider.of<LibraryProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        title: const Text(
          "Toutes les Séries",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: libraryProvider.isLoadingShows
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A4DC)),
            )
          : libraryProvider.errorMessage != null
              ? _buildErrorView(libraryProvider.errorMessage!)
              : libraryProvider.shows.isEmpty
                  ? _buildEmptyStateView()
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 140,
                        mainAxisExtent: 250,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: libraryProvider.shows.length,
                      itemBuilder: (context, index) {
                        final item = libraryProvider.shows[index];
                        return MediaCard(
                          media: item,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SeasonsScreen(show: item),
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
                Provider.of<LibraryProvider>(context, listen: false).loadShows();
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
            Icon(Icons.tv_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              "Aucune série indexée",
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              "Vérifiez que votre dossier Docker /media/Series contient des dossiers par série et des épisodes nommés SxxExx, puis synchronisez depuis l'accueil.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
