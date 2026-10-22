import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_deferred_keyboard.dart';
import 'package:onyx/tv/tv_focus_guard.dart';
import 'package:onyx/tv/tv_mode.dart';
import 'package:onyx/tv/web_tv_field_exit.dart';

/// Sur un téléviseur LG, le clavier virtuel se referme sans que le champ perde
/// le focus, et Flutter Web laisse les flèches au curseur : sans
/// [WebTvFieldExit], la télécommande restait dans le premier champ ouvert.
void main() {
  setUp(() {
    TvMode.enabled.value = true;
    WebTvFieldExit.install();
  });
  tearDown(() {
    WebTvFieldExit.debugUninstall();
    TvMode.enabled.value = false;
  });

  /// Deux champs, le second ouvert à la saisie, sous le garde-fou de l'app :
  /// c'est lui qui donnait le focus lâché à l'élément suivant.
  Future<GlobalKey<TvDeferredKeyboardState>> pumpField(
    WidgetTester tester, {
    int maxLines = 1,
  }) async {
    final key = GlobalKey<TvDeferredKeyboardState>();
    Widget field({Key? key}) => TvDeferredKeyboard(
          key: key,
          builder: (context, focusNode, canRequestFocus) => TextField(
            focusNode: focusNode,
            canRequestFocus: canRequestFocus,
            maxLines: maxLines,
          ),
        );
    await tester.pumpWidget(TvScope(
      isTv: true,
      child: TvFocusGuard(
        child: MaterialApp(
          home: Scaffold(
            body: Column(children: [field(), field(key: key), field()]),
          ),
        ),
      ),
    ));
    key.currentState!.requestKeyboard();
    await tester.pumpAndSettle();
    return key;
  }

  bool editing(WidgetTester tester) =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  /// Le focus est sur le cadre de ce champ-là, pas sur un voisin.
  bool onFrameOf(GlobalKey<TvDeferredKeyboardState> key) {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.debugLabel == 'tv-deferred-keyboard' &&
        focus?.context?.findAncestorStateOfType<TvDeferredKeyboardState>() ==
            key.currentState;
  }

  for (final arrow in [
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowUp,
  ]) {
    testWidgets('${arrow.keyLabel} rend la télécommande au cadre du champ',
        (tester) async {
      final key = await pumpField(tester);
      expect(editing(tester), isTrue);

      await tester.sendKeyEvent(arrow);
      await tester.pumpAndSettle();

      expect(editing(tester), isFalse);
      expect(onFrameOf(key), isTrue);
    });
  }

  testWidgets('un texte sur plusieurs lignes garde ses flèches',
      (tester) async {
    await pumpField(tester, maxLines: 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(editing(tester), isTrue);
  });

  testWidgets('hors téléviseur, le champ garde ses flèches', (tester) async {
    await pumpField(tester);
    TvMode.enabled.value = false;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(editing(tester), isTrue);
  });
}
