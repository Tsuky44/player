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

  // Le compte en épisodes : « encore N, puis coupe ». Le lecteur demande
  // avant d'enchaîner si l'épisode à l'écran est le dernier.
  test('un seul épisode : le lecteur s’arrête à sa fin', () {
    timer.retain();
    timer.startEpisodes(1);

    expect(timer.isActive, isTrue);
    expect(timer.stopsAfterThisEpisode, isTrue);

    timer.episodeFinished();
    expect(timer.isActive, isFalse);
    expect(timer.stopsAfterThisEpisode, isFalse);
  });

  test('le compte en épisodes suit d’un épisode au suivant', () {
    timer.retain();
    timer.startEpisodes(3);
    expect(timer.stopsAfterThisEpisode, isFalse);

    timer.episodeFinished();
    // Le suivant s'ouvre avant que le précédent ne se ferme.
    timer.retain();
    timer.release();
    expect(timer.episodesLeft, 2);
    expect(timer.episodesChosen, 3);

    timer.episodeFinished();
    expect(timer.stopsAfterThisEpisode, isTrue);
  });

  test('sans compte en épisodes, une fin d’épisode ne change rien', () {
    timer.retain();
    var notified = 0;
    timer.addListener(() => notified++);

    timer.episodeFinished();

    expect(notified, 0);
    expect(timer.isActive, isFalse);
  });

  testWidgets('durée et épisodes se remplacent l’un l’autre', (tester) async {
    timer.retain();
    timer.start(const Duration(minutes: 5));
    timer.startEpisodes(2);

    expect(timer.chosen, isNull);
    await tester.pump(const Duration(minutes: 5));
    // La durée abandonnée ne coupe pas au milieu de l'épisode.
    expect(timer.isDue, isFalse);

    timer.start(const Duration(minutes: 5));
    expect(timer.episodesLeft, isNull);
    expect(timer.stopsAfterThisEpisode, isFalse);

    // Avant la fin du test : il refuse de se terminer sur une minuterie qui
    // court encore.
    timer.resetForTest();
  });

  // La fin du fichier tombait sur une carte (épisode à venir, saison
  // suivante) avant d'arriver à la minuterie : le lecteur restait ouvert toute
  // la nuit. La fin du dernier épisode se prend avant tout le reste.
  test('la fin du dernier épisode du compte se prend une seule fois', () {
    timer.retain();
    timer.startEpisodes(2);
    expect(timer.takeLastEpisodeEnd(), isFalse,
        reason: 'il en reste un après celui-ci');
    expect(timer.episodesLeft, 2);

    timer.episodeFinished();
    var notified = 0;
    timer.addListener(() => notified++);
    expect(timer.takeLastEpisodeEnd(), isTrue);
    expect(timer.isActive, isFalse);
    expect(notified, 1);
    expect(timer.takeLastEpisodeEnd(), isFalse);
  });

  test('sans compte en épisodes, une fin de fichier ne ferme rien', () {
    timer.retain();
    expect(timer.takeLastEpisodeEnd(), isFalse);
  });

  test('quitter le lecteur oublie le compte en épisodes', () {
    timer.retain();
    timer.startEpisodes(2);

    timer.release();

    expect(timer.isActive, isFalse);
  });
}
