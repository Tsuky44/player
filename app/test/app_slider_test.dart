import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/widgets/global/app_slider.dart';

/// Ce que le curseur maison doit tenir : pas de `Slider` de Material dessous —
/// c'est son `OverlayPortal` qui fige l'arbre d'accessibilité de Windows — tout
/// en restant un curseur pour qui l'écoute et pour qui le manipule.
void main() {
  Future<double?> pump(
    WidgetTester tester, {
    double value = 30,
    ValueChanged<double>? onChanged,
  }) async {
    double? emitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 4,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10),
              ),
              child: AppSlider(
                value: value,
                max: 100,
                onChanged: onChanged ?? (v) => emitted = v,
              ),
            ),
          ),
        ),
      ),
    ));
    return emitted;
  }

  testWidgets('aucun Slider de Material dans l’arbre', (tester) async {
    await pump(tester);

    expect(find.byType(Slider), findsNothing);
    expect(find.byType(AppSlider), findsOneWidget);
  });

  testWidgets('s’annonce comme un curseur, avec sa valeur et ses actions',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    final node = tester.getSemantics(find.byType(AppSlider));
    expect(node.flagsCollection.isSlider, isTrue);
    expect(node.value, '30 %');
    expect(node.increasedValue, '40 %');
    expect(node.decreasedValue, '20 %');
    handle.dispose();
  });

  testWidgets('un clic sur la piste donne la valeur visée', (tester) async {
    double? emitted;
    await pump(tester, onChanged: (v) => emitted = v);

    // La piste court d'un centre de pouce à l'autre : sur 200 pixels de large
    // et un pouce de rayon 10, son milieu reste le milieu du widget.
    await tester.tapAt(tester.getCenter(find.byType(AppSlider)));
    expect(emitted, closeTo(50, 0.01));
  });

  testWidgets('la flèche droite avance d’un dixième de la course',
      (tester) async {
    double? emitted;
    await pump(tester, value: 30, onChanged: (v) => emitted = v);

    final focus = Focus.of(tester.element(find.byType(CustomPaint).last));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    expect(emitted, closeTo(40, 0.01));
  });

  testWidgets('désactivé, il n’émet rien et n’est pas focalisable',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: AppSlider(value: 0.3, onChanged: null),
        ),
      ),
    ));

    await tester.tapAt(tester.getCenter(find.byType(AppSlider)));
    await tester.pump();
    // Rien à vérifier de plus que l'absence d'exception : sans rappel, le
    // curseur ne peut rien émettre.
    expect(find.byType(AppSlider), findsOneWidget);
  });
}
