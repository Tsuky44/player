import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/library/widgets/season_preview.dart';
import 'package:onyx/screens/library/widgets/season_tabs.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';

/// La souris laissée sur l'onglet d'une saison ouvre sa fiche ; un clic sur
/// la fiche mène à la page de la saison, un clic sur l'onglet change
/// seulement de saison.
void main() {
  final seasons = [
    Media(
      id: 11,
      type: MediaType.season,
      title: 'Saison 1',
      seasonNumber: 1,
      duration: 0,
      overview: 'Tout commence ici.',
      releaseDate: '2021-03-04',
      episodeCount: 8,
      createdAt: DateTime(2026),
    ),
    Media(
      id: 12,
      type: MediaType.season,
      title: 'Saison 2',
      seasonNumber: 2,
      duration: 0,
      createdAt: DateTime(2026),
    ),
  ];

  Future<({List<Media> selected, List<Media> opened})> pumpTabs(
      WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selected = <Media>[];
    final opened = <Media>[];
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: ApiClient(),
        child: MaterialApp(
          home: Scaffold(
            body: SeasonTabs(
              seasons: seasons,
              selected: seasons.first,
              onSelected: selected.add,
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    );
    return (selected: selected, opened: opened);
  }

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
    return mouse;
  }

  testWidgets('le survol prolongé d’un onglet ouvre la fiche de la saison',
      (tester) async {
    await pumpTabs(tester);
    await hover(tester, find.text('Saison 1'));

    expect(find.byType(SeasonPreviewCard), findsNothing,
        reason: 'un curseur qui traverse la rangée n’ouvre rien');

    await tester.pump(SeasonHoverPreview.openDelay);
    await tester.pumpAndSettle();

    expect(find.byType(SeasonPreviewCard), findsOneWidget);
    expect(find.text('Tout commence ici.'), findsOneWidget);
    expect(find.text('2021 · 8 épisodes'), findsOneWidget);
  });

  testWidgets('un clic sur la fiche ouvre la page de la saison',
      (tester) async {
    final calls = await pumpTabs(tester);
    final mouse = await hover(tester, find.text('Saison 1'));
    await tester.pump(SeasonHoverPreview.openDelay);
    await tester.pumpAndSettle();

    await mouse.moveTo(tester.getCenter(find.text('Voir la saison')));
    await tester.pump();
    await tester.tap(find.text('Voir la saison'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(calls.opened.map((s) => s.id), [11]);
    expect(calls.selected, isEmpty);
    expect(find.byType(SeasonPreviewCard), findsNothing);
  });

  testWidgets('la fiche se ferme quand le curseur quitte l’onglet',
      (tester) async {
    await pumpTabs(tester);
    final mouse = await hover(tester, find.text('Saison 2'));
    await tester.pump(SeasonHoverPreview.openDelay);
    await tester.pumpAndSettle();
    expect(find.text('Pas de résumé pour cette saison.'), findsOneWidget);

    await mouse.moveTo(const Offset(1300, 850));
    await tester.pump(SeasonHoverPreview.closeDelay);
    await tester.pumpAndSettle();

    expect(find.byType(SeasonPreviewCard), findsNothing);
  });

  testWidgets('un clic sur l’onglet change de saison sans ouvrir sa page',
      (tester) async {
    final calls = await pumpTabs(tester);
    await tester.tap(find.text('Saison 2'));
    await tester.pumpAndSettle();

    expect(calls.selected.map((s) => s.id), [12]);
    expect(calls.opened, isEmpty);
  });
}
