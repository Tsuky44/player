import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/progress_revision_watch.dart';

/// Le serveur vu par le sondeur : répond tout de suite sans `since` ou quand
/// le jeton s'en écarte déjà, sinon garde la requête jusqu'au changement.
class _Server {
  String revision = 'a';
  bool down = false;

  /// Vrai : ne répond plus à rien, comme un réseau qui ne rend pas la main.
  bool silent = false;
  final asked = <String?>[];
  final _waiting = <(String, Completer<String>)>[];

  int get open => _waiting.where((w) => !w.$2.isCompleted).length;

  Future<String> fetch(String? since, CancelToken cancelToken) {
    asked.add(since);
    if (down) return Future.error(StateError('hors ligne'));
    if (!silent && (since == null || since != revision)) {
      return Future.value(revision);
    }
    final held = Completer<String>();
    _waiting.add((since ?? '', held));
    cancelToken.whenCancel.then((_) {
      if (!held.isCompleted) held.completeError(StateError('annulée'));
    });
    return held.future;
  }

  void change(String next) {
    revision = next;
    for (final (_, held) in _waiting) {
      if (!held.isCompleted) held.complete(next);
    }
  }

  /// La fenêtre du long-poll se referme : même jeton, rien de neuf.
  void closeWindow() {
    for (final (since, held) in _waiting) {
      if (!held.isCompleted) held.complete(since);
    }
  }
}

void main() {
  late _Server server;
  late int changes;
  late ProgressRevisionWatch watch;

  setUp(() {
    server = _Server();
    changes = 0;
    watch = ProgressRevisionWatch(
      fetch: server.fetch,
      onChanged: () => changes++,
    );
  });

  // L'accueil et les fiches restaient figés sur la progression lue à leur
  // ouverture pendant que la série avançait sur un autre appareil : il fallait
  // relancer l'app. Le jeton du serveur qui bouge doit suffire à les relire,
  // à l'instant où il bouge.
  testWidgets('prévient dès que la progression bouge ailleurs, pas avant',
      (tester) async {
    watch.start();
    await tester.pump();
    expect(changes, 0, reason: 'la première réponse est le point de départ');
    expect(server.open, 1, reason: 'une requête reste ouverte sur le jeton');
    expect(server.asked, [null, 'a']);

    server.change('b');
    await tester.pump();
    expect(changes, 1);

    await tester.pump(watch.changePause);
    expect(server.asked.last, 'b', reason: 'l\'attente repart du jeton neuf');

    server.change('c');
    await tester.pump();
    expect(changes, 2);
    watch.stop();
  });

  // Un lecteur ouvert sur la télé écrit sa position toutes les cinq secondes :
  // l'accueil du téléphone posé à côté se relisait en entier à ce rythme
  // pendant tout le film.
  testWidgets('des changements rapprochés ne font relire qu\'une fois par souffle',
      (tester) async {
    watch.start();
    await tester.pump();

    server.change('b');
    await tester.pump();
    expect(changes, 1, reason: 'le premier changement est annoncé à l\'instant');

    for (final next in ['c', 'd', 'e']) {
      await tester.pump(const Duration(seconds: 4));
      server.change(next);
    }
    await tester.pump();
    expect(changes, 1, reason: 'rien de plus pendant le souffle');

    await tester.pump(watch.changePause);
    expect(changes, 2, reason: 'un seul avis pour tout ce qui a bougé entre-temps');
    watch.stop();
  });

  // Une app récente devant un serveur d'avant le long-poll : il ignore
  // `since` et répond tout de suite. Sans garde, il était sondé chaque seconde.
  testWidgets('un serveur qui ne tient pas la requête n\'est pas martelé',
      (tester) async {
    watch.start();
    await tester.pump();
    final askedBefore = server.asked.length;

    server.closeWindow();
    await tester.pump();
    await tester.pump(watch.idlePause);
    expect(server.asked.length, askedBefore,
        reason: 'réponse à vide immédiate : pas de nouvelle requête au bout '
            'du simple souffle');

    await tester.pump(watch.retryDelay);
    expect(server.asked.length, askedBefore + 1);
    watch.stop();
  });

  testWidgets('une fenêtre refermée sans changement ne relit rien',
      (tester) async {
    watch.start();
    await tester.pump();

    await tester.pump(const Duration(seconds: 20));
    server.closeWindow();
    await tester.pump();
    expect(changes, 0);
    expect(server.open, 0, reason: 'un souffle avant de rouvrir');

    await tester.pump(watch.idlePause);
    expect(server.open, 1);
    expect(changes, 0);
    watch.stop();
  });

  // Sortie du lecteur, retour d'une fiche, réveil de l'app : l'écran se relit
  // d'office, même si le jeton n'a pas bougé et même sans serveur pour le dire.
  testWidgets('refresh prévient une fois au retour à l\'écran', (tester) async {
    watch.start(refresh: true);
    await tester.pump();
    expect(changes, 1);
    expect(server.asked.first, isNull,
        reason: 'le point de départ est lu avant de relire : la dernière '
            'position du lecteur peut arriver juste après');

    await tester.pump(const Duration(seconds: 30));
    expect(changes, 1);
    watch.stop();
  });

  testWidgets('refresh prévient aussi quand le serveur ne répond pas',
      (tester) async {
    server.down = true;
    watch.start(refresh: true);
    await tester.pump();
    expect(changes, 1);
    watch.stop();
  });

  testWidgets('refresh n\'attend pas un réseau qui ne rend pas la main',
      (tester) async {
    server.silent = true;
    watch.start(refresh: true);
    await tester.pump();
    expect(changes, 0);

    await tester.pump(watch.baselineTimeout);
    expect(changes, 1);
    watch.stop();
  });

  // Sous le lecteur ou dans un onglet caché, la requête ouverte ne sert à
  // rien — et les battements du lecteur feraient relire l'accueil en boucle.
  testWidgets('stop referme la requête ouverte et ne prévient plus',
      (tester) async {
    watch.start();
    await tester.pump();
    expect(server.open, 1);

    watch.stop();
    await tester.pump();
    expect(server.open, 0);

    server.change('b');
    await tester.pump(const Duration(seconds: 30));
    expect(changes, 0);
    expect(server.open, 0);
  });

  testWidgets('un échec se retente plus tard sans inventer de changement',
      (tester) async {
    watch.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    server.closeWindow();
    server.down = true;
    await tester.pump(watch.idlePause);
    final askedWhileDown = server.asked.length;

    await tester.pump(watch.retryDelay - const Duration(seconds: 1));
    expect(server.asked.length, askedWhileDown, reason: 'pas de martèlement');

    server.down = false;
    await tester.pump(const Duration(seconds: 1));
    expect(server.open, 1);
    expect(changes, 0);
    watch.stop();
  });
}
