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

  group('poster grid columns follow the poster size, not breakpoints', () {
    double cell(double contentWidth,
        {double gap = AppLayout.posterGridCrossSpacing}) {
      final columns = AppLayout.posterGridCount(contentWidth, spacing: gap);
      return (contentWidth - gap * (columns - 1)) / columns;
    }

    test('a cell stays close to the target size at every width', () {
      for (var contentWidth = 320.0; contentWidth <= 3000; contentWidth += 17) {
        final width = cell(contentWidth);
        if (AppLayout.posterGridCount(contentWidth) <= 2) continue;
        expect(
          width,
          greaterThanOrEqualTo(AppLayout.posterTileMin),
          reason: 'cells too narrow at $contentWidth',
        );
        expect(
          width,
          lessThan(AppLayout.posterTileTarget * 1.45),
          reason: 'cells too wide at $contentWidth',
        );
      }
    });

    test('a wider row never shows fewer posters', () {
      var previous = 0;
      for (var contentWidth = 320.0; contentWidth <= 3000; contentWidth += 7) {
        final columns = AppLayout.posterGridCount(contentWidth);
        expect(columns, greaterThanOrEqualTo(previous),
            reason: 'column count dropped at $contentWidth');
        previous = columns;
      }
    });

    test('phones keep two large posters, desktops get many', () {
      // iPhone 390pt minus the 16pt gutters, compact spacing.
      expect(
        AppLayout.posterGridCount(358,
            spacing: AppLayout.posterGridCompactCrossSpacing),
        2,
      );
      // 1440pt window minus the 48pt gutters.
      expect(AppLayout.posterGridCount(1344), greaterThanOrEqualTo(8));
      // 1920pt window minus the 48pt gutters.
      expect(AppLayout.posterGridCount(1824), greaterThanOrEqualTo(11));
    });
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
