import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/away_from_screen.dart';
import 'package:onyx/utils/on_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reconcileWithServer', () {
    test('sans réponse du serveur, le lecteur reste où il était', () {
      expect(reconcileWithServer(localSeconds: 600, server: null),
          isA<StayHere>());
    });

    test('la position qu\'on a envoyée en partant ne fait pas bouger', () {
      expect(
        reconcileWithServer(
            localSeconds: 600, server: (positionSeconds: 604, finished: false)),
        isA<StayHere>(),
      );
    });

    test('un autre appareil a avancé : le lecteur se cale sur lui', () {
      final verdict = reconcileWithServer(
          localSeconds: 600, server: (positionSeconds: 1500, finished: false));
      expect(verdict, isA<SeekTo>());
      expect((verdict as SeekTo).seconds, 1500);
    });

    test('un autre appareil a fini ce média : on quitte le lecteur', () {
      expect(
        reconcileWithServer(
            localSeconds: 600, server: (positionSeconds: 0, finished: true)),
        isA<LeavePlayer>(),
      );
    });
  });

  test('parseServerProgress lit la réponse de /api/progress', () {
    expect(
      parseServerProgress(
          {'current_position_seconds': 42, 'is_finished': true}),
      (positionSeconds: 42, finished: true),
    );
    expect(parseServerProgress({}), (positionSeconds: 0, finished: false));
  });

  group('PlayerAwayGuard', () {
    late List<String> log;
    late bool enabled;
    late ServerProgress? server;
    late PlayerAwayGuard guard;

    setUp(() {
      AppForeground.debugSetVisible(true);
      log = [];
      enabled = true;
      server = (positionSeconds: 1500, finished: false);
      guard = PlayerAwayGuard(
        enabled: () => enabled,
        pause: () => log.add('pause'),
        closeSession: () async => log.add('close'),
        reopenSession: () => log.add('reopen'),
        localSeconds: () => 600,
        fetchProgress: () async => server,
        apply: (verdict) => log.add(switch (verdict) {
          StayHere() => 'stay',
          SeekTo(:final seconds) => 'seek:$seconds',
          LeavePlayer() => 'leave',
        }),
      )..attach();
    });

    tearDown(() {
      guard.dispose();
      AppForeground.debugSetVisible(true);
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    // La panne d'origine : la TV éteinte laissait le lecteur lire et battre,
    // puis il repartait de sa propre position au rallumage.
    test('TV éteinte : pause et séance fermée ; rallumée : recalage', () async {
      AppForeground.debugSetVisible(false);
      expect(log, ['pause', 'close']);

      AppForeground.debugSetVisible(true);
      await settle();
      expect(log, ['pause', 'close', 'reopen', 'seek:1500']);
    });

    test('hors TV, quitter l\'app ne touche pas à la lecture', () async {
      enabled = false;
      AppForeground.debugSetVisible(false);
      AppForeground.debugSetVisible(true);
      await settle();
      expect(log, isEmpty);
    });

    test('le serveur injoignable au réveil laisse le lecteur en place',
        () async {
      guard.dispose();
      guard = PlayerAwayGuard(
        enabled: () => true,
        pause: () {},
        closeSession: () async {},
        reopenSession: () {},
        localSeconds: () => 600,
        fetchProgress: () async => throw Exception('hors ligne'),
        apply: (verdict) => log.add(verdict is StayHere ? 'stay' : 'moved'),
      )..attach();
      AppForeground.debugSetVisible(false);
      AppForeground.debugSetVisible(true);
      await settle();
      expect(log, ['stay']);
    });
  });
}
