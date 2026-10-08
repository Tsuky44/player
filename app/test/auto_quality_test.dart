import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/auto_quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ladder = <QualityTier>[
  QualityTier(key: '2160p', label: '4K · 12 Mbit/s', height: 2160, bitrateBps: 12000000),
  QualityTier(key: '1080p-10', label: '1080p · 10 Mbit/s', height: 1080, bitrateBps: 10000000),
  QualityTier(key: '1080p', label: '1080p · 6 Mbit/s', height: 1080, bitrateBps: 6000000),
  QualityTier(key: '1080p-4', label: '1080p · 4 Mbit/s', height: 1080, bitrateBps: 4000000),
  QualityTier(key: '720p', label: '720p · 3,5 Mbit/s', height: 720, bitrateBps: 3500000),
  QualityTier(key: '720p-2', label: '720p · 2 Mbit/s', height: 720, bitrateBps: 2000000),
  QualityTier(key: '360p', label: '360p · 1 Mbit/s', height: 360, bitrateBps: 1000000),
];

final _t0 = DateTime(2026, 10, 8, 20);
const _film = Duration(hours: 2);

/// Nourrit [auto] d'un relevé par seconde : l'avance part de [from] et varie
/// de [slope] secondes par seconde. Rend le dernier verdict.
AutoVerdict _play(
  AutoQuality auto, {
  required int startSecond,
  required int seconds,
  required double from,
  required double slope,
  double speed = 1,
  Duration remaining = _film,
  List<AutoVerdict>? seen,
}) {
  var verdict = AutoVerdict.steady;
  for (var i = 0; i < seconds; i++) {
    final buffered = from + slope * i;
    verdict = auto.noteSample(
      _t0.add(Duration(seconds: startSecond + i)),
      buffered: Duration(milliseconds: (buffered < 0 ? 0 : buffered * 1000).round()),
      remaining: remaining,
      playing: true,
      speed: speed,
    );
    seen?.add(verdict);
  }
  return verdict;
}

AutoLadder _at(
  String? key, {
  int source = 20000000,
  int height = 2160,
  bool direct = true,
  String? ceiling,
  int current = 0,
  int ceilingBps = 0,
}) =>
    AutoLadder(
      tiers: _ladder,
      currentKey: key,
      sourceHeight: height,
      sourceBps: source,
      currentBps: current,
      directAllowed: direct,
      ceilingKey: ceiling,
      ceilingBps: ceilingBps,
    );

/// La qualité automatique (ADR-0056) : elle descend sur la pente du tampon,
/// avant la coupure, et ne remonte que sur une mesure.
void main() {
  group('descendre', () {
    test('un tampon qui fond sous le seuil accuse la ligne avant la coupure',
        () {
      final auto = AutoQuality();
      // La ligne livre la moitié du film : l'avance perd 0,5 s par seconde.
      final verdict =
          _play(auto, startSecond: 0, seconds: 20, from: 14, slope: -0.5);

      expect(verdict, AutoVerdict.starving);
      expect(auto.fillRatio, closeTo(0.5, 0.05));
    });

    test('pour viser, ce sont les dernières secondes qui comptent', () {
      final auto = AutoQuality();
      // La ligne suivait, puis tombe à la moitié du débit : la fenêtre
      // entière mêle les deux et lirait encore près de 90 %.
      _play(auto, startSecond: 0, seconds: 14, from: 9, slope: 0.4);
      final seen = <AutoVerdict>[];
      _play(auto,
          startSecond: 14, seconds: 14, from: 14.6, slope: -0.5, seen: seen);

      expect(seen, contains(AutoVerdict.starving));
      final at = seen.indexOf(AutoVerdict.starving);
      expect(at, lessThan(12), reason: 'accusée avant que le tampon soit vide');
      final again = AutoQuality();
      _play(again, startSecond: 0, seconds: 14, from: 9, slope: 0.4);
      _play(again, startSecond: 14, seconds: at + 1, from: 14.6, slope: -0.5);
      expect(again.fillRatio, closeTo(0.5, 0.1));
    });

    test('tant que l’avance reste confortable, la ligne a le temps de se '
        'reprendre', () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      _play(auto,
          startSecond: 0, seconds: 20, from: 120, slope: -0.5, seen: seen);

      expect(seen, everyElement(isNot(AutoVerdict.starving)));
    });

    test('un tampon plat, même mince, n’accuse personne', () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 0, seconds: 40, from: 6, slope: 0, seen: seen);

      expect(seen, everyElement(isNot(AutoVerdict.starving)));
    });

    test('un tampon nourri par segments monte en dents de scie sans alerter',
        () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      for (var i = 0; i < 60; i++) {
        // Deux secondes arrivent d'un coup toutes les deux secondes.
        final buffered = 10.0 + (i.isEven ? 1.0 : 0.0);
        seen.add(auto.noteSample(
          _t0.add(Duration(seconds: i)),
          buffered: Duration(milliseconds: (buffered * 1000).round()),
          remaining: _film,
          playing: true,
        ));
      }

      expect(seen, everyElement(isNot(AutoVerdict.starving)));
    });

    test('après une recherche, le tampon qui se regarnit ne compte pas', () {
      final auto = AutoQuality();
      auto.noteDisturbance(_t0);
      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 0, seconds: 14, from: 8, slope: -0.5, seen: seen);

      expect(seen, everyElement(AutoVerdict.steady));
      expect(auto.noteStall(_t0.add(const Duration(seconds: 5))), isFalse);
    });

    test('en fin de film, le tampon fond parce qu’il n’y a plus rien à '
        'recevoir', () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      for (var i = 0; i < 25; i++) {
        final left = Duration(seconds: 30 - i);
        seen.add(auto.noteSample(
          _t0.add(Duration(seconds: i)),
          buffered: left,
          remaining: left,
          playing: true,
        ));
      }

      expect(seen, everyElement(AutoVerdict.steady));
    });

    test('à vitesse double, un tampon qui tient n’est pas une ligne lente',
        () {
      final auto = AutoQuality();
      // Lue à 2×, la ligne livre 1,8 s de film par seconde : 90 %.
      _play(auto,
          startSecond: 0, seconds: 20, from: 14, slope: -0.2, speed: 2);

      expect(auto.fillRatio, closeTo(0.9, 0.03));
    });

    test('une coupure suffit, sans en attendre trois', () {
      final auto = AutoQuality();
      expect(auto.noteStall(_t0.add(const Duration(minutes: 1))), isTrue);
      // Faute d'avoir mesuré la pente, la ligne est supposée nettement courte.
      expect(auto.fillRatio, AutoQuality.blindRatio);
    });

    test('en pause, rien ne se mesure', () {
      final auto = AutoQuality();
      _play(auto, startSecond: 0, seconds: 10, from: 14, slope: -0.5);
      auto.noteSample(_t0.add(const Duration(seconds: 10)),
          buffered: const Duration(seconds: 9),
          remaining: _film,
          playing: false);
      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 11, seconds: 8, from: 9, slope: -0.5, seen: seen);

      expect(seen, everyElement(AutoVerdict.steady),
          reason: 'la fenêtre repart de zéro à la reprise');
    });
  });

  group('choisir le barreau', () {
    test('un seul saut jusqu’à ce que la ligne porte, marge comprise', () {
      // Fichier à 20 Mbit/s, la ligne en livre la moitié : 10, dont 80 % font
      // 8 — le premier barreau à 8 ou moins est 1080p · 6.
      expect(_at(null).down(0.5)?.tier?.key, '1080p');
    });

    test('depuis un barreau, on descend d’autant que la ligne manque', () {
      // 6 × 0,5 × 0,8 = 2,4 Mbit/s.
      expect(_at('1080p').down(0.5)?.tier?.key, '720p-2');
    });

    test('jamais un barreau plus lourd que le fichier', () {
      expect(_at(null, source: 3000000, height: 1080).down(0.9)?.tier?.key,
          '720p-2');
    });

    test('une ligne plus courte que tout prend le dernier barreau', () {
      expect(_at('720p-2').down(0.1)?.tier?.key, '360p');
    });

    test('au bas de l’échelle, il n’y a plus rien à demander', () {
      expect(_at('360p').down(0.5), isNull);
    });

    test('le barreau natif n’est pas une descente : recopié, il pèse le '
        'fichier', () {
      // Fichier 1080p à 10 Mbit/s, ligne à 90 % : 7,2 Mbit/s. « 1080p · 6 »
      // tiendrait sur le papier, mais le serveur y recopie le fichier.
      expect(_at(null, source: 10000000, height: 1080).down(0.9)?.tier?.key,
          '1080p-4');
    });

    test('une session qui recopie l’image pèse le fichier, pas son barreau',
        () {
      // Sur le barreau natif recopié (10 Mbit/s envoyés), une ligne à moitié
      // porte 5, dont 80 % font 4.
      final ladder = _at('1080p',
          source: 10000000,
          height: 1080,
          direct: false,
          ceiling: '1080p',
          current: 10000000,
          ceilingBps: 10000000);
      expect(ladder.down(0.5)?.tier?.key, '1080p-4');
    });

    test('sans débit de fichier connu, il est supposé peser son barreau '
        'natif', () {
      expect(_at(null, source: 0, height: 1080).down(0.5)?.tier?.key,
          '720p-2');
    });

    test('un serveur sans échelle de débits ne donne rien à choisir', () {
      const ladder = AutoLadder(
        tiers: [
          QualityTier(key: '1080p', label: '1080p', height: 1080, bitrateBps: 0),
        ],
        currentKey: null,
        sourceHeight: 1080,
      );
      expect(ladder.down(0.5), isNull);
    });
  });

  group('remonter', () {
    AutoTarget? up(int capacity,
            {String? current = '720p-2',
            bool direct = true,
            int source = 20000000,
            String? ceiling,
            int ceilingBps = 0}) =>
        _at(current,
                source: source,
                direct: direct,
                ceiling: ceiling,
                ceilingBps: ceilingBps)
            .up(capacity);

    test('une lecture stable demande une mesure après le délai, pas avant',
        () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 0, seconds: 89, from: 20, slope: 0, seen: seen);
      expect(seen, everyElement(AutoVerdict.steady));

      expect(_play(auto, startSecond: 89, seconds: 3, from: 20, slope: 0),
          AutoVerdict.canClimb);
    });

    test('avec la fin du film en mémoire, on peut encore remonter', () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      for (var i = 0; i < 120; i++) {
        final left = Duration(seconds: 300 - i);
        seen.add(auto.noteSample(
          _t0.add(Duration(seconds: i)),
          buffered: left,
          remaining: left,
          playing: true,
        ));
      }

      expect(seen, isNot(contains(AutoVerdict.starving)));
      expect(seen.last, AutoVerdict.canClimb);
      expect(auto.measuredRatio, 0,
          reason: 'la lecture ne tire plus rien : toute la ligne est libre');
    });

    test('la mesure doit dépasser le barreau d’une fois et demie', () {
      // 9 Mbit/s mesurés : 6 × 1,5 = 9 passe, 10 × 1,5 = 15 non.
      expect(up(9000000)?.tier?.key, '1080p');
      expect(up(8900000)?.tier?.key, '1080p-4');
    });

    test('le fichier tel quel dès que la ligne le porte largement', () {
      expect(up(30000000), const AutoTarget.direct());
      expect(up(29000000)?.isDirect, isFalse);
    });

    test('pas de barreau plus lourd que le fichier : au-dessus, c’est lui',
        () {
      // Fichier à 5 Mbit/s : 1080p · 6 et au-delà n'ont aucun sens.
      expect(up(7400000, source: 5000000)?.tier?.key, '1080p-4');
      expect(up(7500000, source: 5000000), const AutoTarget.direct());
    });

    test('quand l’appareil ne lit pas le fichier, le sommet est le barreau '
        'pris à sa place', () {
      expect(up(100000000, direct: false, ceiling: '1080p')?.tier?.key,
          '1080p');
      expect(up(100000000, current: '1080p', direct: false, ceiling: '1080p'),
          isNull);
    });

    test('un sommet recopié se juge au débit du fichier', () {
      // Le barreau « 1080p · 6 » recopie un fichier à 10 Mbit/s : il faut 15
      // pour y remonter, pas 9.
      AutoTarget? climb(int capacity) => up(capacity,
          source: 10000000,
          direct: false,
          ceiling: '1080p',
          ceilingBps: 10000000);

      expect(climb(14000000)?.tier?.key, '1080p-4');
      expect(climb(15000000)?.tier?.key, '1080p');
    });

    test('rien à remonter depuis le Direct Play, ni sur une mesure trop '
        'courte', () {
      expect(up(100000000, current: null), isNull);
      expect(up(2500000), isNull);
    });

    test('la mesure vise le sommet, pas plus', () {
      expect(_at('360p').climbDemandBps, 30000000);
      expect(_at('360p', direct: false, ceiling: '1080p').climbDemandBps,
          9000000);
    });

    test('une mesure qui ne justifie rien double l’attente suivante', () {
      final auto = AutoQuality();
      auto.noteClimbRefused(_t0);
      expect(auto.climbWait, const Duration(seconds: 180));

      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 0, seconds: 179, from: 20, slope: 0, seen: seen);
      expect(seen, everyElement(AutoVerdict.steady));
    });

    test('redescendre juste après une remontée la désavoue', () {
      final auto = AutoQuality();
      auto.noteMoved(_t0, up: true);
      auto.noteMoved(_t0.add(const Duration(minutes: 1)), up: false);

      expect(auto.climbWait, const Duration(seconds: 180));
    });

    test('l’attente ne dépasse pas son plafond', () {
      final auto = AutoQuality();
      for (var i = 0; i < 10; i++) {
        auto.noteClimbRefused(_t0);
      }
      expect(auto.climbWait, const Duration(minutes: 10));
    });

    test('une remontée qui tient remet l’attente à son départ', () {
      final auto = AutoQuality();
      auto.noteClimbRefused(_t0);
      auto.noteMoved(_t0, up: true);
      _play(auto, startSecond: 200, seconds: 2, from: 20, slope: 0);

      expect(auto.climbWait, const Duration(seconds: 90));
    });

    test('une descente sans remontée avant repart d’une attente courte', () {
      final auto = AutoQuality();
      auto.noteClimbRefused(_t0);
      auto.noteMoved(_t0.add(const Duration(minutes: 20)), up: false);

      expect(auto.climbWait, const Duration(seconds: 90));
    });

    test('choisie dans le menu, l’Auto mesure dès que la lecture est stable',
        () {
      final auto = AutoQuality();
      auto.noteClimbRefused(_t0);
      auto.noteChosen(_t0);

      expect(_play(auto, startSecond: 0, seconds: 14, from: 20, slope: 0),
          AutoVerdict.canClimb);
    });

    test('pas de mesure sur une avance trop mince pour la payer', () {
      final auto = AutoQuality();
      final seen = <AutoVerdict>[];
      _play(auto, startSecond: 0, seconds: 120, from: 5, slope: 0, seen: seen);

      expect(seen, everyElement(AutoVerdict.steady));
    });
  });

  group('le réglage', () {
    setUp(AutoQualityPreference.resetForTest);

    test('activé d’office', () async {
      SharedPreferences.setMockInitialValues({});
      await AutoQualityPreference.initialize();
      expect(AutoQualityPreference.enabled, isTrue);
    });

    test('qui avait éteint l’adaptation d’avant garde son choix', () async {
      SharedPreferences.setMockInitialValues({'adaptive_quality': false});
      await AutoQualityPreference.initialize();
      expect(AutoQualityPreference.enabled, isFalse);
    });

    test('le nouveau réglage l’emporte sur l’ancien', () async {
      SharedPreferences.setMockInitialValues(
          {'adaptive_quality': false, 'auto_quality': true});
      await AutoQualityPreference.initialize();
      expect(AutoQualityPreference.enabled, isTrue);

      await AutoQualityPreference.setEnabled(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_quality'), isFalse);
    });
  });
}
