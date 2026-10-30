import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/poster_grid_zoom.dart';
import 'package:onyx/utils/responsive.dart';
import 'package:onyx/widgets/global/app_slider.dart';
import 'package:onyx/widgets/global/poster_grid_zoom_region.dart';
import 'package:onyx/widgets/global/poster_grid_zoom_slider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Le curseur de densité règle le même écart que Ctrl + molette : tirer vers la
/// droite agrandit les affiches (moins de colonnes), vers la gauche en met
/// davantage, et la grille de sa page suit.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PosterGridZoom.instance.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PosterGridZoomRegion(
            child: CustomScrollView(
              slivers: [
                const SliverPosterGridZoomBar(),
                SliverLayoutBuilder(
                  builder: (context, constraints) => SliverGrid(
                    gridDelegate: AppLayout.posterGridDelegate(
                      context,
                      constraints.crossAxisExtent,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => const SizedBox.shrink(),
                      childCount: 60,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int columns(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
        .crossAxisCount;
  }

  double sliderValue(WidgetTester tester) =>
      tester.widget<AppSlider>(find.byType(AppSlider)).value;

  testWidgets('le curseur part du nombre de colonnes de la grille',
      (tester) async {
    await pumpPage(tester);
    // La base de la grille n'est connue qu'après sa première mise en page : le
    // curseur la reçoit à l'image suivante.
    await tester.pump();

    expect(
        sliderValue(tester),
        PosterGridZoom.minColumns +
            PosterGridZoom.maxColumns -
            columns(tester));
  });

  testWidgets('tirer le curseur à droite agrandit les affiches',
      (tester) async {
    await pumpPage(tester);
    await tester.pump();
    final before = columns(tester);

    final rect = tester.getRect(find.byType(AppSlider));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();

    expect(columns(tester), PosterGridZoom.minColumns);
    expect(columns(tester), lessThan(before));
  });

  testWidgets('tirer le curseur à gauche met le maximum d\'affiches',
      (tester) async {
    await pumpPage(tester);
    await tester.pump();

    final rect = tester.getRect(find.byType(AppSlider));
    await tester.tapAt(Offset(rect.left + 2, rect.center.dy));
    await tester.pump();

    expect(columns(tester), PosterGridZoom.maxColumns);
    expect(PosterGridZoom.instance.offset, greaterThan(0));
  });

  testWidgets('le réglage est enregistré pour la prochaine séance',
      (tester) async {
    await pumpPage(tester);
    await tester.pump();

    final rect = tester.getRect(find.byType(AppSlider));
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('poster_grid_zoom_offset'), isNot(0));
  });
}
