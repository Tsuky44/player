import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/widgets/global/detail_metadata.dart';
import 'package:onyx/widgets/global/detail_synopsis.dart';

Widget _host(String overview) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: DetailSynopsis(
              title: 'Severance',
              overview: overview,
              maxLines: 3,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('un synopsis coupé ouvre le texte complet au toucher',
      (tester) async {
    final overview = List.filled(40, 'Une phrase assez longue.').join(' ');
    await tester.pumpWidget(_host(overview));

    await tester.tap(find.byType(DetailSynopsis));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text(overview), findsNWidgets(2));

    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets("un synopsis coupé s'ouvre à la télécommande", (tester) async {
    final overview = List.filled(40, 'Une phrase assez longue.').join(' ');
    await tester.pumpWidget(_host(overview));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets("un synopsis qui tient en entier ne s'ouvre pas",
      (tester) async {
    await tester.pumpWidget(_host('Court.'));

    await tester.tap(find.byType(DetailSynopsis));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  test('la ligne de métadonnées porte au plus trois genres, après la note',
      () {
    final chips = buildMetadataChips(
      type: MediaType.show,
      releaseDate: '2022-02-18',
      rating: 8.4,
      seasons: 2,
      genres: const ['Drame', 'Mystère', 'Science-fiction', 'Thriller'],
    );

    expect(chips[chips.length - 2], isA<RatingBadge>());
    expect(
      (chips.last as MetadataText).label,
      'Drame, Mystère, Science-fiction',
    );
  });
}
