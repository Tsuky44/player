import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/poster_grid_zoom.dart';
import 'package:onyx/utils/responsive.dart';
import 'package:onyx/widgets/global/poster_grid_zoom_region.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ctrl + molette change le nombre d'affiches par ligne de toutes les grilles
/// du catalogue ; la molette seule continue de faire défiler la page.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PosterGridZoom.instance.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester, ScrollController controller) {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PosterGridZoomRegion(
            child: CustomScrollView(
              controller: controller,
              slivers: [
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

  Future<void> wheel(WidgetTester tester, double dy) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(600, 400)));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('Ctrl + molette vers le bas ajoute des affiches par ligne',
      (tester) async {
    await pumpPage(tester, ScrollController());
    final before = columns(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await wheel(tester, 100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(columns(tester), before + 1);
  });

  testWidgets('Ctrl + molette vers le haut en retire, jusqu\'à 2 colonnes',
      (tester) async {
    await pumpPage(tester, ScrollController());
    final before = columns(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await wheel(tester, -100);
    expect(columns(tester), before - 1);

    for (var i = 0; i < 30; i++) {
      await wheel(tester, -100);
    }
    expect(columns(tester), PosterGridZoom.minColumns);

    // À la butée, un cran dans l'autre sens agit tout de suite.
    await wheel(tester, 100);
    expect(columns(tester), PosterGridZoom.minColumns + 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('la molette seule fait défiler sans changer le zoom',
      (tester) async {
    final controller = ScrollController();
    await pumpPage(tester, controller);
    final before = columns(tester);

    await wheel(tester, 100);

    expect(columns(tester), before);
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('pendant Ctrl, la page ne défile pas', (tester) async {
    final controller = ScrollController();
    await pumpPage(tester, controller);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    // Une image passe entre l'appui sur Ctrl et la molette, comme en vrai.
    await tester.pump();
    await wheel(tester, 100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(controller.offset, 0);
  });
}
