import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/progress_revision_watch.dart';

void main() {
  const interval = Duration(seconds: 5);

  // L'accueil et les fiches restaient figés sur la progression lue à leur
  // ouverture pendant que la série avançait sur un autre appareil : il fallait
  // relancer l'app. Le jeton du serveur qui bouge doit suffire à les relire.
  testWidgets('prévient quand la progression a bougé ailleurs, pas avant',
      (tester) async {
    var revision = 'a';
    var changes = 0;
    final watch = ProgressRevisionWatch(
      fetch: () async => revision,
      onChanged: () => changes++,
      interval: interval,
    );

    watch.start();
    await tester.pump();
    expect(changes, 0, reason: 'la première réponse est le point de départ');

    await tester.pump(interval);
    expect(changes, 0, reason: 'un jeton identique ne relit rien');

    revision = 'b';
    await tester.pump(interval);
    expect(changes, 1);

    await tester.pump(interval);
    expect(changes, 1, reason: 'un seul avis par changement');
    watch.stop();
  });

  testWidgets('au retour à l\'écran, signale ce qui a changé entre-temps',
      (tester) async {
    var revision = 'a';
    var changes = 0;
    var fetches = 0;
    final watch = ProgressRevisionWatch(
      fetch: () async {
        fetches++;
        return revision;
      },
      onChanged: () => changes++,
      interval: interval,
    );

    watch.start();
    await tester.pump();
    watch.stop();

    revision = 'b';
    final fetchesWhileHidden = fetches;
    await tester.pump(interval * 3);
    expect(fetches, fetchesWhileHidden, reason: 'caché, il ne sonde plus');
    expect(changes, 0);

    watch.start();
    await tester.pump();
    expect(changes, 1);
    watch.stop();
  });

  // L'accueil se relit déjà seul à chaque retour : le prévenir en plus lui
  // ferait charger /api/home deux fois à chaque sortie du lecteur.
  testWidgets('adoptFirst repart du jeton courant sans prévenir',
      (tester) async {
    var revision = 'a';
    var changes = 0;
    final watch = ProgressRevisionWatch(
      fetch: () async => revision,
      onChanged: () => changes++,
      interval: interval,
    );

    watch.start(adoptFirst: true);
    await tester.pump();
    watch.stop();

    revision = 'b';
    watch.start(adoptFirst: true);
    await tester.pump();
    expect(changes, 0);

    revision = 'c';
    await tester.pump(interval);
    expect(changes, 1);
    watch.stop();
  });

  testWidgets('un sondage en échec ne casse rien et n\'invente pas de changement',
      (tester) async {
    var fail = false;
    var changes = 0;
    final watch = ProgressRevisionWatch(
      fetch: () async {
        if (fail) throw StateError('hors ligne');
        return 'a';
      },
      onChanged: () => changes++,
      interval: interval,
    );

    watch.start();
    await tester.pump();
    fail = true;
    await tester.pump(interval);
    fail = false;
    await tester.pump(interval);
    expect(changes, 0);
    watch.stop();
  });
}
