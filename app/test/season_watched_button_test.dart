import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/widgets/global/season_watched_button.dart';

/// « J'ai fini cette saison » : ce que le bouton envoie à l'écran qui le porte,
/// et la place qu'il prend sur la ligne du sélecteur de saison.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HomeMediaItem episode(int id,
          {bool available = true, bool finished = false}) =>
      HomeMediaItem(
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
        currentPositionSeconds: finished ? 2400 : 0,
        duration: 2400,
        isFinished: finished,
        showId: 7,
        showTitle: 'Une série au titre plutôt long',
      );

  late List<int> sentIds;
  late bool? sentWatched;

  setUp(() {
    sentIds = [];
    sentWatched = null;
  });

  /// La ligne du sélecteur de saison telle que l'écran d'une série la
  /// construit : un `Wrap`, pour que le bouton passe à la ligne au lieu de
  /// déborder quand la saison porte un nom long.
  Widget harness(List<HomeMediaItem> episodes,
      {required Size size, String seasonLabel = 'Saison 2'}) {
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: size.width,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Text(seasonLabel),
                ),
                SeasonWatchedButton(
                  episodes: episodes,
                  onSetWatched: (changed, watched) async {
                    sentIds = [for (final e in changed) e.media.id];
                    sentWatched = watched;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('ne marque que ce qui reste à voir', (tester) async {
    await tester.pumpWidget(harness(
      [
        episode(1, finished: true),
        episode(2),
        episode(3),
        // Un épisode que le serveur n'a pas ne peut pas avoir été vu.
        episode(4, available: false),
      ],
      size: const Size(1200, 800),
    ));
    await tester.pump();

    await tester.tap(find.text('Marquer la saison vue'));
    await tester.pump();

    expect(sentWatched, isTrue);
    expect(sentIds, [2, 3]);
  });

  testWidgets('propose le retour en arrière quand tout est vu', (tester) async {
    await tester.pumpWidget(harness(
      [episode(1, finished: true), episode(2, finished: true)],
      size: const Size(1200, 800),
    ));
    await tester.pump();

    await tester.tap(find.text('Saison vue'));
    await tester.pump();

    expect(sentWatched, isFalse);
    expect(sentIds, [1, 2]);
  });

  testWidgets(
      'ne déborde pas d’un téléphone étroit, nom de saison long compris',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(
      [for (var i = 1; i <= 12; i++) episode(i)],
      size: const Size(360, 800),
      seasonLabel: 'Spéciaux de fin d’année',
    ));
    await tester.pump();

    // Un débordement lève une exception de rendu : c'est elle qu'on guette,
    // parce qu'elle raye l'écran en jaune et noir sur un vrai appareil.
    expect(tester.takeException(), isNull);
    expect(find.text('Marquer la saison vue'), findsOneWidget);
  });

  testWidgets('disparaît quand la saison n’a aucun épisode disponible',
      (tester) async {
    await tester.pumpWidget(harness(
      [episode(1, available: false), episode(2, available: false)],
      size: const Size(1200, 800),
    ));
    await tester.pump();

    expect(find.byType(SeasonWatchedButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });
}
