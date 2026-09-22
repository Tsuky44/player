import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/tv_focus.dart';
import 'package:onyx/tv/tv_mode.dart';

/// The root the app builds: remote shortcuts plus [TvBackAction]. The test
/// host is not Android, which is the case the action exists for (iOS).
Widget _app() {
  return MaterialApp(
    shortcuts: <ShortcutActivator, Intent>{
      ...WidgetsApp.defaultShortcuts,
      ...tvSelectShortcuts,
    },
    actions: <Type, Action<Intent>>{
      ...WidgetsApp.defaultActions,
      TvBackIntent: TvBackAction(),
    },
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(
                body: TextButton(
                  autofocus: true,
                  onPressed: null,
                  child: Text('détail'),
                ),
              ),
            ),
          ),
          child: const Text('accueil'),
        ),
      ),
    ),
  );
}

Future<void> _openDetail(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.tap(find.text('accueil'));
  await tester.pumpAndSettle();
  expect(find.text('détail'), findsOneWidget);
}

void main() {
  tearDown(() => TvMode.enabled.value = false);

  // Escape is what the Siri Remote's Menu button and a keyboard send, B what a
  // controller sends. (goBack is Android's, where the system does the work.)
  for (final key in [
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
  ]) {
    testWidgets('${key.debugName} goes back one page in TV mode',
        (tester) async {
      TvMode.enabled.value = true;
      await _openDetail(tester);

      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();

      expect(find.text('détail'), findsNothing);
      expect(find.text('accueil'), findsOneWidget);
    });
  }

  testWidgets('Escape keeps its desktop meaning outside TV mode',
      (tester) async {
    await _openDetail(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('détail'), findsOneWidget);
  });
}
