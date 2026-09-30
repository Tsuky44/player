import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/widgets/player_episodes_panel.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/download_preferences.dart';
import 'package:onyx/services/network_status.dart';
import 'package:onyx/widgets/global/media_download_button.dart';
import 'package:onyx/widgets/global/season_download_button.dart';
import 'package:provider/provider.dart';

/// Lancer un téléchargement depuis le panneau des épisodes du lecteur, sans
/// repasser par la fiche de la série.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomeMediaItem episode(int id, {bool watched = false}) => HomeMediaItem(
        media: Media(
          id: id,
          type: MediaType.episode,
          title: 'Épisode $id',
          duration: 2400,
          seasonNumber: 1,
          episodeNumber: id,
          isAvailable: true,
          createdAt: DateTime(2026),
        ),
        currentPositionSeconds: 0,
        duration: 2400,
        isFinished: watched,
        showId: 7,
        showTitle: 'Ma série',
      );

  testWidgets('chaque épisode et la suite de la saison se téléchargent d’ici',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final episodes = [for (var i = 1; i <= 4; i++) episode(i, watched: i == 1)];
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: ApiClient()),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
        ChangeNotifierProvider<DownloadPreferences>.value(
            value: DownloadPreferences.instance),
        ChangeNotifierProvider<NetworkStatus>(create: (_) => NetworkStatus()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PlayerEpisodesPanel(
                showTitle: 'Ma série',
                currentEpisodeId: 2,
                seasons: const [],
                selectedSeasonId: 0,
                onSeasonChanged: (_) {},
                episodes: episodes,
                isLoading: false,
                onClose: () {},
                onEpisodeSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(SeasonDownloadButton), findsOneWidget);
    expect(find.text('Télécharger les non vus · 3 épisodes'), findsOneWidget);
    // « À suivre » (épisodes 3 et 4) puis la saison entière (1 à 4).
    expect(find.byType(MediaDownloadButton), findsNWidgets(6));
  });
}
