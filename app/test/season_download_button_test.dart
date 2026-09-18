import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/download_preferences.dart';
import 'package:onyx/services/network_status.dart';
import 'package:onyx/widgets/global/season_download_button.dart';
import 'package:provider/provider.dart';

/// « Toute la saison d'un coup » : ce que le bouton dit, et la place qu'il
/// prend sur la ligne qu'il partage avec le titre de la section.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomeMediaItem episode(int id, {bool available = true}) => HomeMediaItem(
        media: Media(
          id: id,
          type: MediaType.episode,
          title: 'Épisode $id',
          duration: 2400,
          seasonNumber: 2,
          episodeNumber: id,
          isAvailable: available,
          createdAt: DateTime(2026),
        ),
        currentPositionSeconds: 0,
        duration: 2400,
        isFinished: false,
        showId: 7,
        showTitle: 'Une série au titre plutôt long',
      );

  Widget harness(List<HomeMediaItem> episodes, {required Size size}) {
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadManager>.value(
              value: DownloadManager.instance),
          ChangeNotifierProvider<DownloadPreferences>.value(
              value: DownloadPreferences.instance),
          ChangeNotifierProvider<NetworkStatus>(create: (_) => NetworkStatus()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              child: Row(
                children: [
                  const Text('Épisodes'),
                  const SizedBox(width: 12),
                  const Flexible(
                    child: Text('12/12 disponibles',
                        overflow: TextOverflow.ellipsis),
                  ),
                  const Spacer(),
                  SeasonDownloadButton(
                    episodes: episodes,
                    showTitle: 'Une série au titre plutôt long',
                    showId: 7,
                    seasonNumber: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tient sur la ligne d’un téléphone étroit', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(
      [for (var i = 1; i <= 12; i++) episode(i)],
      size: const Size(360, 800),
    ));
    await tester.pump();

    // Un débordement de Row lève une exception de rendu : c'est elle qu'on
    // guette, parce qu'elle raye l'écran en jaune et noir sur un vrai appareil.
    expect(tester.takeException(), isNull);
    expect(find.text('La saison'), findsOneWidget);
  });

  testWidgets('se dit en entier quand il y a la place', (tester) async {
    await tester.pumpWidget(harness(
      [for (var i = 1; i <= 12; i++) episode(i)],
      size: const Size(1200, 800),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Télécharger la saison'), findsOneWidget);
  });

  testWidgets('disparaît quand la saison n’a aucun épisode disponible',
      (tester) async {
    await tester.pumpWidget(harness(
      [episode(1, available: false), episode(2, available: false)],
      size: const Size(1200, 800),
    ));
    await tester.pump();

    expect(find.byType(TextButton), findsNothing);
  });
}
