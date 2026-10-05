import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/player_screen_lock.dart';

void main() {
  late int unlocked;
  late int tapsUnderneath;

  Future<void> pumpLock(WidgetTester tester) async {
    unlocked = 0;
    tapsUnderneath = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapsUnderneath++,
              ),
              PlayerScreenLock(onUnlock: () => unlocked++),
            ],
          ),
        ),
      ),
    );
  }

  Finder padlock() => find.byIcon(Icons.lock_rounded);

  double padlockOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(of: padlock(), matching: find.byType(AnimatedOpacity)),
      )
      .opacity;

  testWidgets('aucun toucher n’atteint le lecteur sous le verrou',
      (tester) async {
    await pumpLock(tester);

    await tester.tapAt(const Offset(100, 100));
    await tester.tap(padlock());
    await tester.pump();

    expect(tapsUnderneath, 0);
    expect(unlocked, 0);
  });

  testWidgets('maintenir le cadenas deux secondes déverrouille',
      (tester) async {
    await pumpLock(tester);

    final gesture = await tester.startGesture(tester.getCenter(padlock()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1900));
    expect(unlocked, 0);

    await tester.pump(const Duration(milliseconds: 200));
    expect(unlocked, 1);
    await gesture.up();
  });

  testWidgets('relâcher avant la fin ne déverrouille pas et vide l’anneau',
      (tester) async {
    await pumpLock(tester);

    final first = await tester.startGesture(tester.getCenter(padlock()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await first.up();
    await tester.pumpAndSettle();
    expect(unlocked, 0);

    // L'appui suivant repart de zéro : 1,5 s + 1,5 s ne font pas 2 s.
    final second = await tester.startGesture(tester.getCenter(padlock()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(unlocked, 0);
    await second.up();
  });

  testWidgets('le cadenas s’efface seul, un appui sur l’image le ramène',
      (tester) async {
    await pumpLock(tester);
    expect(padlockOpacity(tester), 1);

    await tester.pump(PlayerScreenLock.padlockLinger);
    await tester.pump();
    expect(padlockOpacity(tester), 0);

    // Effacé, il ne prend plus le doigt : un appui là où il était ne compte
    // que comme un appui sur l'image.
    final ghost = await tester.startGesture(tester.getCenter(padlock()));
    await tester.pump(const Duration(seconds: 3));
    await ghost.up();
    expect(unlocked, 0);

    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(padlockOpacity(tester), 1);
  });

  testWidgets('le cadenas ne s’efface pas sous le doigt qui le tient',
      (tester) async {
    await pumpLock(tester);

    await tester.pump(const Duration(milliseconds: 2500));
    final gesture = await tester.startGesture(tester.getCenter(padlock()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    expect(padlockOpacity(tester), 1);
    await gesture.up();
  });
}
