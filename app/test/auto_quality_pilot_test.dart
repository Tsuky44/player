import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/hooks/use_auto_quality.dart';
import 'package:onyx/screens/player/playback/auto_descent.dart';
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

  /// Ce que la sonde répond au moment de descendre.
  AutoSounding sounding = const AutoSounding();
  int soundings = 0;
  final passives = <bool>[];
  final sideMeasures = <bool>[];

  /// Ce que le moteur dit recevoir pendant une mesure, null s'il ne dit rien.
  int? inUseBps;

  final moves = <String>[];
  final urgent = <bool>[];
  final measures = <int>[];

  late final AutoQualityPilot pilot = AutoQualityPilot(
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
        maxEncodeHeight: pilot.maxEncodeHeight,
      ),
    ),
    sound: ({required passive, sideMeasure = false}) async {
      soundings++;
      passives.add(passive);
      sideMeasures.add(sideMeasure);
      return sounding;
    },
    measureLine: (wantBps) async {
      measures.add(wantBps);
      final spare = lineBps;
      return spare == null ? null : (spareBps: spare, inUseBps: inUseBps);
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
    // 10 Mbit/s mesurés pour un fichier à 20.
    final playback = _Playback()
      ..slope = -0.5
      ..sounding = const AutoSounding(lineBps: 10000000);
    await playback.play(50);

    expect(playback.moves, ['1080p-10'],
        reason: 'un barreau à la fois, sur deux mesures concordantes');
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
    final playback = _Playback()
      ..slope = -0.5
      ..sounding = const AutoSounding(lineBps: 10000000);
    await playback.play(50);
    // Après la grâce du changement de source, le tampon fond encore.
    playback
      ..buffered = 14
      ..sounding = const AutoSounding();
    await playback.play(40);

    expect(playback.moves, ['1080p-10', '1080p']);
  });

  test('une coupure sur un barreau fait descendre tout de suite, dans '
      'l’urgence', () async {
    final playback = _Playback()
      ..quality = '1080p'
      ..buffered = 60;
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
      ..sounding = const AutoSounding(lineBps: 10000000)
      ..moveSucceeds = false;
    await playback.play(50);

    expect(playback.moves, ['1080p-10']);
    expect(playback.quality, isNull);
  });

  group('avec une ligne mesurée', () {
    test('une coupure en Direct Play va droit au barreau que la ligne tient',
        () async {
      // 20 Mbit/s de fichier, 2,6 de ligne : une seule mesure ne descend pas,
      // deux concordantes descendent d'un barreau.
      final playback = _Playback()
        ..buffered = 60
        ..sounding = const AutoSounding(lineBps: 2600000);
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty);
      await playback.play(20);
      await playback.pilot.noteStall();

      expect(playback.moves, ['1080p-10']);
      expect(playback.urgent, [true]);
    });

    test('un tampon qui fond aussi', () async {
      final playback = _Playback()
        ..slope = -0.5
        ..sounding = const AutoSounding(lineBps: 1300000);
      await playback.play(50);

      expect(playback.moves, ['1080p-10'],
          reason: 'deux mesures concordantes, un barreau à la fois');
      expect(playback.soundings, 2);
      expect(playback.sideMeasures, [true, true],
          reason: 'un cache plein ne reçoit que ce qu’il lit : la ligne se '
              'mesure à côté');
    });

    test('une ligne qui tient ce qui est lu : la première coupure passe, '
        'la deuxième descend d’un cran', () async {
      final playback = _Playback()
        ..quality = '1080p'
        ..buffered = 60
        ..sounding = const AutoSounding(lineBps: 50000000);
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty);

      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, ['720p-2']);
    });
  });

  group('pendant un délai de grâce', () {
    test('une coupure n’accuse rien sans mesure', () async {
      final playback = _Playback()..buffered = 5;
      playback.pilot.noteDisturbance();
      await playback.play(5);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
      expect(playback.passives, [true],
          reason: 'rien qui coûte à la ligne, ni l’avis d’un encodeur qui '
              'vient de démarrer');
    });

    test('une ligne mesurée sous le débit lu fait descendre sans attendre',
        () async {
      // Mesuré : un film à 41 Mbit/s sur une ligne à 5 restait figé dix-huit
      // secondes après sa première image.
      final playback = _Playback()
        ..buffered = 1
        ..sounding = const AutoSounding(lineBps: 4800000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty, reason: 'une mesure ne suffit pas');
      await playback.play(4);
      await playback.pilot.noteStall();

      expect(playback.moves, ['1080p-10']);
      expect(playback.urgent, [true]);
    });

    test('une ligne qui livre ce qui est lu n’est pas accusée, même sans '
        'marge', () async {
      final playback = _Playback()
        ..quality = '1080p'
        ..buffered = 1
        ..sounding = const AutoSounding(lineBps: 6500000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
    });
  });

  test('ce que le moteur reçoit pendant la mesure remplace l’estimation',
      () async {
    // 3 Mbit/s à côté d'une lecture qui en reçoit 2 : 5 en tout. La pente
    // du tampon aurait fait compter davantage et remonter à tort.
    final playback = _Playback()
      ..quality = '720p-2'
      ..buffered = 20
      ..slope = 0.9
      ..lineBps = 3000000
      ..inUseBps = 2000000;
    await playback.play(100);

    expect(playback.measures, isNotEmpty);
    expect(playback.moves, isEmpty);
  });

  group('quand c’est le serveur qui ne suit pas', () {
    test('une image plus petite, et pas de descente en débit', () async {
      final playback = _Playback()
        ..quality = '1080p'
        ..buffered = 60
        ..sounding = const AutoSounding(encoderBehind: true);
      await playback.play(30);
      await playback.pilot.noteStall();

      expect(playback.moves, ['720p-2']);
      expect(playback.pilot.maxEncodeHeight, 720);
    });

    test('rien de plus petit : on ne bouge pas, et on ne remonte pas',
        () async {
      final playback = _Playback()
        ..quality = '360p'
        ..buffered = 60
        ..sounding = const AutoSounding(encoderBehind: true);
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty);
      expect(playback.pilot.maxEncodeHeight, 360);

      // Le serveur a repris de l'avance : la ligne justifierait 1080p, que
      // le serveur ne tient pas. Le fichier, lui, ne lui coûte rien.
      playback
        ..sounding = const AutoSounding()
        ..lineBps = 100000000;
      await playback.play(200);
      expect(playback.moves, ['direct']);
    });

    test('si la ligne porte le fichier, c’est lui qu’on lit', () async {
      // Mesuré : un serveur à 0,6× restait à 360p, figé toutes les trente
      // secondes, sur une ligne qui portait le fichier vingt fois.
      final playback = _Playback()
        ..quality = '720p-2'
        ..buffered = 60
        ..sounding = const AutoSounding(encoderBehind: true);
      await playback.play(30);
      playback.lineBps = 100000000;
      await playback.pilot.noteStall();

      expect(playback.moves, ['direct']);
      expect(playback.pilot.maxEncodeHeight, 0,
          reason: 'aucun barreau n’a été condamné');
    });

    test('redemander l’Auto dans le menu lui rend toute l’échelle', () async {
      final playback = _Playback()
        ..quality = '1080p'
        ..buffered = 60
        ..sounding = const AutoSounding(encoderBehind: true);
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.pilot.maxEncodeHeight, 720);

      playback.pilot
        ..enabled = false
        ..enabled = true;
      expect(playback.pilot.maxEncodeHeight, 0);
    });
  });

  group('le Direct Play d’abord (ADR-0065)', () {
    test('un cache plein qui fond ne fait pas transcoder : la mesure disculpe '
        'la ligne, et la pente n’est plus crue', () async {
      // Le tampon d'un moteur plafonné fond le temps de se recharger : la
      // pente d'une ligne à la moitié du fichier, sur une ligne qui en porte
      // cinq fois le débit.
      final playback = _Playback()
        ..slope = -0.5
        ..sounding = const AutoSounding(lineBps: 100000000);
      await playback.play(20);
      expect(playback.moves, isEmpty);
      expect(playback.soundings, 1);

      // Le cache se recharge et refond : rien n'est remesuré de trois
      // minutes.
      for (var cycle = 0; cycle < 4; cycle++) {
        playback.buffered = 14;
        await playback.play(30);
      }
      expect(playback.moves, isEmpty);
      expect(playback.soundings, 1);
    });

    test('sans mesure, une pente ne quitte pas le Direct Play', () async {
      final playback = _Playback()..slope = -0.5;
      await playback.play(60);

      expect(playback.moves, isEmpty);
      expect(playback.quality, isNull);
    });

    test('deux coupures sur une ligne qui porte le fichier passent, la '
        'troisième en trois minutes descend', () async {
      final playback = _Playback()
        ..buffered = 60
        ..sounding = const AutoSounding(lineBps: 50000000);
      await playback.play(30);
      await playback.pilot.noteStall();
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty);

      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, ['1080p-10']);
    });

    test('des coupures espacées de plus de trois minutes ne s’additionnent '
        'pas', () async {
      final playback = _Playback()
        ..buffered = 60
        ..sounding = const AutoSounding(lineBps: 50000000);
      for (var i = 0; i < 4; i++) {
        await playback.play(100);
        await playback.pilot.noteStall();
      }

      expect(playback.moves, isEmpty);
    });

    test('une coupure sans mesure ne quitte le Direct Play qu’à la troisième',
        () async {
      final playback = _Playback()..buffered = 60;
      await playback.play(30);
      await playback.pilot.noteStall();
      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, isEmpty);

      await playback.play(30);
      await playback.pilot.noteStall();
      expect(playback.moves, hasLength(1));
    });

    test('pendant un délai de grâce, une ligne à peine sous le fichier ne fait '
        'pas quitter le Direct Play', () async {
      // 18 Mbit/s reçus pour un fichier à 20 : un moteur qui vient d'ouvrir
      // reçoit encore moins que ce que la ligne porte.
      final playback = _Playback()
        ..buffered = 1
        ..sounding = const AutoSounding(lineBps: 18000000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
    });

    test('sur un barreau aussi, une ligne disculpée ne se réaccuse pas sur '
        'la pente', () async {
      final playback = _Playback()
        ..quality = '1080p'
        ..slope = -0.5
        ..sounding = const AutoSounding(lineBps: 50000000);
      for (var cycle = 0; cycle < 4; cycle++) {
        playback.buffered = 14;
        await playback.play(30);
      }

      expect(playback.moves, isEmpty);
      expect(playback.soundings, 1);
    });
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

  group('descendre sans faux positif (journaux Windows 1.1.30)', () {
    test('cache plein : une coupure juste après une recherche ne mesure rien',
        () async {
      // 20,8 Mbit/s « mesurés » alors que mpv avait 90 s en mémoire.
      final playback = _Playback()
        ..buffered = 100
        ..sounding = const AutoSounding(lineBps: 20800000);
      playback.pilot.noteDisturbance();
      await playback.play(3);
      await playback.pilot.noteStall();
      await playback.play(6);
      await playback.pilot.noteStall();

      expect(playback.soundings, 0, reason: 'le moteur ne téléchargeait pas');
      expect(playback.moves, isEmpty);
    });

    test('une seule mesure basse ne fait jamais descendre, ni à 360p',
        () async {
      final playback = _Playback()
        ..buffered = 2
        ..sounding = const AutoSounding(lineBps: 1800000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
    });

    test('une recherche entre deux mesures annule la première', () async {
      final playback = _Playback()
        ..buffered = 2
        ..sounding = const AutoSounding(lineBps: 4800000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();
      playback.pilot.noteDisturbance();
      await playback.play(5);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
    });

    test('une mesure normale entre deux basses les annule', () async {
      final playback = _Playback()
        ..buffered = 2
        ..sounding = const AutoSounding(lineBps: 4800000);
      playback.pilot.noteDisturbance();
      await playback.play(2);
      await playback.pilot.noteStall();
      playback.sounding = const AutoSounding(lineBps: 90000000);
      await playback.play(4);
      await playback.pilot.noteStall();
      playback.sounding = const AutoSounding(lineBps: 4800000);
      await playback.play(4);
      await playback.pilot.noteStall();

      expect(playback.moves, isEmpty);
    });

    test('un vrai débit faible descend d’un seul barreau sur deux mesures',
        () async {
      final playback = _Playback()
        ..buffered = 2
        ..sounding = const AutoSounding(lineBps: 1800000);
      playback.pilot.noteDisturbance();
      for (var i = 0; i < 2; i++) {
        await playback.play(4);
        await playback.pilot.noteStall();
      }
      expect(playback.moves, ['1080p-10']);
    });
  });

  group('AutoDescentGate', () {
    final t0 = DateTime(2026, 10, 30, 1);

    test('deux mesures espacées confirment, une seule non', () {
      final gate = AutoDescentGate()..noteLow(t0, 1000000);
      expect(gate.confirmed(t0), isFalse);
      gate.noteLow(t0.add(const Duration(seconds: 5)), 1500000);
      expect(gate.confirmed(t0.add(const Duration(seconds: 5))), isTrue);
      expect(gate.confirmedBig(t0.add(const Duration(seconds: 5))), isFalse);
      expect(gate.confirmedBps(t0.add(const Duration(seconds: 5))), 1500000);
    });

    test('deux relevés du même instant ne font qu’une mesure', () {
      final gate = AutoDescentGate()
        ..noteLow(t0, 1000000)
        ..noteLow(t0.add(const Duration(seconds: 1)), 1000000);
      expect(gate.confirmed(t0.add(const Duration(seconds: 1))), isFalse);
    });

    test('une mesure trop vieille ne confirme plus', () {
      final gate = AutoDescentGate()..noteLow(t0, 1000000);
      final later = t0.add(const Duration(minutes: 3));
      gate.noteLow(later, 1000000);
      expect(gate.confirmed(later), isFalse);
    });

    test('un tampon plein ne se mesure pas', () {
      final gate = AutoDescentGate();
      expect(gate.measurable(buffered: const Duration(seconds: 90)), isFalse);
      expect(gate.measurable(buffered: const Duration(seconds: 3)), isTrue);
    });

    test('après une descente, le délai court puis passe', () {
      final gate = AutoDescentGate()..noteDescended(t0);
      expect(gate.coolingDown(t0.add(const Duration(seconds: 10))), isTrue);
      expect(gate.coolingDown(t0.add(const Duration(seconds: 40))), isFalse);
    });
  });
}
