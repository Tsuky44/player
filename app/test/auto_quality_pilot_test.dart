import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/hooks/use_auto_quality.dart';
import 'package:onyx/screens/player/playback/auto_quality.dart';

const _ladder = <QualityTier>[
  QualityTier(key: '1080p-10', label: '1080p · 10 Mbit/s', height: 1080, bitrateBps: 10000000),
  QualityTier(key: '1080p', label: '1080p · 6 Mbit/s', height: 1080, bitrateBps: 6000000),
  QualityTier(key: '720p-2', label: '720p · 2 Mbit/s', height: 720, bitrateBps: 2000000),
  QualityTier(key: '360p', label: '360p · 1 Mbit/s', height: 360, bitrateBps: 1000000),
];

/// Une lecture en carton : une avance qui suit une pente, une ligne d'un
/// débit donné, et le journal de ce que le pilote a demandé.
class _Playback {
  DateTime now = DateTime(2026, 10, 8, 20);
  String? quality;
  double buffered = 14;
  double slope = 0;
  bool eligible = true;
  bool directAllowed = true;
  String? ceilingKey;
  int? lineBps;
  bool moveSucceeds = true;

  final moves = <String>[];
  final urgent = <bool>[];
  final measures = <int>[];

  late final pilot = AutoQualityPilot(
    now: () => now,
    read: () => AutoQualityReading(
      eligible: eligible,
      playing: true,
      buffered: Duration(milliseconds: (buffered * 1000).round()),
      remaining: const Duration(hours: 1),
      ladder: AutoLadder(
        tiers: _ladder,
        currentKey: quality,
        sourceHeight: 2160,
        sourceBps: 20000000,
        directAllowed: directAllowed,
        ceilingKey: ceilingKey,
      ),
    ),
    measureLine: (wantBps) async {
      measures.add(wantBps);
      return lineBps;
    },
    move: (target, {required urgent}) async {
      moves.add(target.toString());
      this.urgent.add(urgent);
      if (moveSucceeds) quality = target.tier?.key;
      return moveSucceeds;
    },
  )..enabled = true;

  Future<void> play(int seconds) async {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      buffered = (buffered + slope).clamp(0, 600);
      await pilot.tick();
    }
  }
}

/// Le pilote de la qualité automatique : il lit, décide par [AutoQuality], et
/// ne fait qu'une chose à la fois. Voir ADR-0056.
void main() {
  test('une ligne qui livre la moitié du fichier fait descendre, une fois, '
      'sans urgence', () async {
    final playback = _Playback()..slope = -0.5;
    await playback.play(20);

    expect(playback.moves, ['1080p']);
    expect(playback.urgent, [false]);
  });

  test('une ligne qui suit ne touche à rien', () async {
    final playback = _Playback()..buffered = 200;
    await playback.play(300);

    expect(playback.moves, isEmpty);
    expect(playback.measures, isEmpty,
        reason: 'en Direct Play il n’y a rien au-dessus à mesurer');
  });

  test('si le premier barreau ne suffit pas, on redescend jusqu’à ce que '
      'ça tienne', () async {
    final playback = _Playback()..slope = -0.5;
    await playback.play(20);
    // Après la grâce du changement de source, le tampon fond encore.
    await playback.play(10);

    expect(playback.moves, ['1080p', '720p-2']);
  });

  test('une coupure fait descendre tout de suite, dans l’urgence', () async {
    final playback = _Playback()..buffered = 60;
    await playback.play(30);
    await playback.pilot.noteStall();

    expect(playback.moves, hasLength(1));
    expect(playback.urgent, [true]);
  });

  test('désactivée, l’Auto ne fait rien, même sur une coupure', () async {
    final playback = _Playback()..slope = -0.5;
    playback.pilot.enabled = false;
    await playback.play(30);
    await playback.pilot.noteStall();

    expect(playback.moves, isEmpty);
  });

  test('pendant un changement de source, les relevés ne comptent pas',
      () async {
    final playback = _Playback()
      ..slope = -0.5
      ..eligible = false;
    await playback.play(30);

    expect(playback.moves, isEmpty);
  });

  test('après une descente, la remontée attend une mesure qui la justifie',
      () async {
    final playback = _Playback()
      ..quality = '720p-2'
      ..buffered = 20
      ..lineBps = 3000000;
    await playback.play(100);

    expect(playback.measures, [30000000],
        reason: 'la mesure vise le fichier : 20 Mbit/s × 1,5');
    expect(playback.moves, isEmpty,
        reason: '3 Mbit/s libres et 2 pris par la lecture ne justifient rien');

    // La ligne s'est rétablie ; la mesure suivante attend deux fois plus.
    playback.lineBps = 40000000;
    await playback.play(80);
    expect(playback.moves, isEmpty);
    await playback.play(30);

    expect(playback.moves, ['direct']);
    expect(playback.quality, isNull);
  });

  test('la remontée va au plus haut que la mesure justifie, pas d’un cran',
      () async {
    final playback = _Playback()
      ..quality = '360p'
      ..buffered = 20
      ..lineBps = 9500000;
    await playback.play(100);

    expect(playback.moves, ['1080p']);
  });

  test('ce que la lecture tire déjà compte dans ce que la ligne porte',
      () async {
    // 7,5 Mbit/s libres à côté d'une lecture qui en prend 2 : 9,5 en tout,
    // de quoi tenir 1080p · 6 (9), que 7,5 seuls n'auraient pas justifié.
    final playback = _Playback()
      ..quality = '720p-2'
      ..buffered = 20
      ..lineBps = 7500000;
    await playback.play(100);

    expect(playback.moves, ['1080p']);
  });

  test('sans Direct Play possible, le sommet est le barreau pris à sa place',
      () async {
    final playback = _Playback()
      ..quality = '1080p'
      ..directAllowed = false
      ..ceilingKey = '1080p'
      ..buffered = 20
      ..lineBps = 100000000;
    await playback.play(300);

    expect(playback.measures, isEmpty);
    expect(playback.moves, isEmpty);
  });

  test('un changement refusé par le serveur laisse la lecture où elle est',
      () async {
    final playback = _Playback()
      ..slope = -0.5
      ..moveSucceeds = false;
    await playback.play(20);

    expect(playback.moves, ['1080p']);
    expect(playback.quality, isNull);
  });

  test('choisie dans le menu depuis un barreau bas, l’Auto mesure sans '
      'attendre son tour', () async {
    final playback = _Playback()
      ..quality = '360p'
      ..buffered = 20
      ..lineBps = 40000000;
    playback.pilot
      ..enabled = false
      ..enabled = true;
    await playback.play(15);

    expect(playback.moves, ['direct']);
  });
}
