import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/onyx/onyx_controls_layer.dart';

/// Le chrome affiché, posé sur une zone qui compte les pointeurs qui
/// l'atteignent — la place de [PlayerTapZones] dans le lecteur, qui déplace la
/// fenêtre quand on glisse l'image.
Future<List<Offset>> _pumpOverPicture(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.reset);

  final reached = <Offset>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => reached.add(event.position),
              ),
            ),
            OnyxControlsLayer(
              visible: true,
              isPlaying: true,
              position: const Duration(minutes: 42),
              duration: const Duration(hours: 2),
              buffered: 0.5,
              title: 'Avatar : La Voie de l’eau',
              overline: '2022',
              volume: 70,
              onPlayPause: () {},
              onRewind: () {},
              onForward: () {},
              onSeekFraction: (_) {},
              onVolumeChanged: (_) {},
              onBack: () {},
              onToggleSubtitles: () {},
              onOpenAudio: () {},
              onCycleSpeed: () {},
              onOpenSettings: () {},
              onToggleFullscreen: () {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return reached;
}

void main() {
  group('le chrome laisse passer les clics hors de ses boutons', () {
    testWidgets('le haut vide de la barre atteint l’image', (tester) async {
      final reached = await _pumpOverPicture(tester);
      await tester.tapAt(const Offset(640, 6));
      await tester.tapAt(const Offset(640, 40));
      expect(reached, hasLength(2));
    });

    testWidgets('le titre des deux barres atteint l’image', (tester) async {
      final reached = await _pumpOverPicture(tester);
      for (final text in find.text('Avatar : La Voie de l’eau').evaluate()) {
        await tester.tapAt(tester.getCenter(find.byWidget(text.widget)));
      }
      expect(reached, hasLength(2));
    });

    testWidgets('un bouton garde son clic', (tester) async {
      final reached = await _pumpOverPicture(tester);
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      expect(reached, isEmpty);
    });
  });
}
