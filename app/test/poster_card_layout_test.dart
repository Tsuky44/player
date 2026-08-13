import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/poster_url.dart';
import 'package:onyx/utils/responsive.dart';
import 'package:onyx/widgets/global/poster_card.dart';

/// The catalog grids (films, séries, collections, filmographies, demandes) all
/// share one cell ratio and one card. These tests pin that contract: the card
/// must fit the cell it is given, and the poster must stay close to 2:3.
void main() {
  Future<void> pumpGrid(WidgetTester tester, double cellWidth) async {
    const ratio = AppLayout.posterGridAspectRatio;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: cellWidth,
              height: cellWidth / ratio,
              child: PosterCard(
                posterUrl: null,
                title: 'Un titre de film particulièrement long',
                subtitle: '2024  •  ★ 8.4',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('card fits its grid cell at every column width', (tester) async {
    for (final width in <double>[110, 150, 180, 220, 260]) {
      await pumpGrid(tester, width);
      expect(tester.takeException(), isNull, reason: 'overflow at $width');
    }
  });

  testWidgets('poster keeps a poster-like ratio', (tester) async {
    await pumpGrid(tester, 180);
    final poster = tester.getSize(find.byType(ClipRRect).first);
    final ratio = poster.height / poster.width;
    expect(ratio, greaterThan(1.4));
    expect(ratio, lessThan(1.7));
  });

  testWidgets('row card height matches the card it renders', (tester) async {
    const width = 150.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: mediaCardHeight(width, compact: true) + 4,
            child: SizedBox(
              width: width,
              child: PosterCard(
                posterUrl: null,
                title: 'Titre',
                subtitle: '2024',
                onTap: () {},
                compact: true,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    final poster = tester.getSize(find.byType(ClipRRect).first);
    expect(poster.height / poster.width, closeTo(1.5, 0.08));
  });

  test('card posters are normalised to TMDB w500', () {
    expect(
      cardPosterUrl('https://image.tmdb.org/t/p/w300/abc.jpg'),
      'https://image.tmdb.org/t/p/w500/abc.jpg',
    );
    expect(
      cardPosterUrl('https://image.tmdb.org/t/p/w500/abc.jpg'),
      'https://image.tmdb.org/t/p/w500/abc.jpg',
    );
    expect(cardPosterUrl(null), isNull);
    expect(
      cardPosterUrl('/posters/local.jpg', serverBaseUrl: 'http://host:8080'),
      'http://host:8080/posters/local.jpg',
    );
  });
}
