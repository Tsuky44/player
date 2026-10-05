import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/sleep_timer.dart';

/// La règle que ce fichier verrouille : la minuterie de veille appartient à la
/// soirée, pas à l'épisode. Réglée sur 30 minutes devant un épisode de 20, elle
/// coupe 10 minutes dans le suivant — alors que chaque épisode a son propre
/// écran de lecture, qui remplace le précédent.
void main() {
  final timer = SleepTimer.instance;

  setUp(timer.resetForTest);
  tearDown(timer.resetForTest);

  testWidgets('la minuterie continue sur l’épisode suivant', (tester) async {
    timer.retain(); // l'épisode de 20 minutes
    timer.start(const Duration(minutes: 30));

    await tester.pump(const Duration(minutes: 20));
    // Le suivant s'ouvre avant que le précédent ne se ferme.
    timer.retain();
    timer.release();

    expect(timer.isActive, isTrue);
    expect(timer.isDue, isFalse);

    await tester.pump(const Duration(minutes: 10));
    expect(timer.isDue, isTrue);
    expect(timer.isActive, isFalse);
  });

  testWidgets('l’échéance n’est prise qu’une fois', (tester) async {
    timer.retain();
    var notified = 0;
    timer.addListener(() => notified++);
    timer.start(const Duration(minutes: 5));
    notified = 0;

    await tester.pump(const Duration(minutes: 5));

    expect(notified, 1);
    expect(timer.takeDue(), isTrue);
    expect(timer.takeDue(), isFalse);
  });

  testWidgets('quitter le lecteur arrête la minuterie', (tester) async {
    timer.retain();
    timer.start(const Duration(minutes: 30));

    timer.release();

    expect(timer.isActive, isFalse);
    await tester.pump(const Duration(minutes: 30));
    // Rien n'attend le film lancé le lendemain.
    expect(timer.isDue, isFalse);
  });

  testWidgets('une échéance que personne n’a prise ne survit pas au lecteur',
      (tester) async {
    timer.retain();
    timer.start(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));

    timer.release();

    expect(timer.isDue, isFalse);
  });

  testWidgets('la relancer repart de la nouvelle durée', (tester) async {
    timer.retain();
    timer.start(const Duration(minutes: 5));
    timer.start(const Duration(minutes: 15));

    await tester.pump(const Duration(minutes: 5));
    expect(timer.isDue, isFalse);
    expect(timer.chosen, const Duration(minutes: 15));

    await tester.pump(const Duration(minutes: 10));
    expect(timer.isDue, isTrue);
  });
}
