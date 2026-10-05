import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/desktop_window.dart';
import 'package:onyx/theme/app_colors.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    bool maximized = false,
  }) async {
    final calls = <String>[];
    // Monté comme dans `main.dart` : au-dessus du Navigator, donc sans
    // Overlay. Un widget qui en exige un (Tooltip) ferait échouer ces tests.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topRight,
          child: WindowControlPills(
            isMaximized: maximized,
            onMinimize: () => calls.add('minimize'),
            onToggleMaximize: () => calls.add('maximize'),
            onClose: () => calls.add('close'),
          ),
        ),
      ),
    );
    return calls;
  }

  Finder pill(Color color) => find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final decoration = w.decoration;
        return decoration is BoxDecoration &&
            decoration.color == color &&
            decoration.shape == BoxShape.circle;
      });

  testWidgets(
      'les contrôles de fenêtre sont des pastilles rondes dans l\'ordre '
      'Windows, fermer tout à droite', (tester) async {
    await pump(tester);

    final minimize = tester.getRect(pill(AppColors.warning));
    final maximize = tester.getRect(pill(AppColors.success));
    final close = tester.getRect(pill(AppColors.error));

    expect(minimize.size, const Size(12, 12));
    expect(minimize.center.dx, lessThan(maximize.center.dx));
    expect(maximize.center.dx, lessThan(close.center.dx));
  });

  testWidgets('chaque pastille déclenche son action', (tester) async {
    final calls = await pump(tester);

    await tester.tap(pill(AppColors.warning));
    await tester.tap(pill(AppColors.success));
    await tester.tap(pill(AppColors.error));

    expect(calls, ['minimize', 'maximize', 'close']);
  });

  testWidgets('les symboles n\'apparaissent qu\'au survol du groupe',
      (tester) async {
    await pump(tester);

    double glyphOpacity() => tester
        .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
        .opacity;
    expect(glyphOpacity(), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(pill(AppColors.success)));
    await tester.pumpAndSettle();

    expect(glyphOpacity(), 1);
  });

  testWidgets('la pastille verte annonce « Restaurer » une fois agrandie',
      (tester) async {
    await pump(tester, maximized: true);

    expect(find.bySemanticsLabel('Restaurer'), findsOneWidget);
    expect(find.bySemanticsLabel('Agrandir'), findsNothing);
  });
}
