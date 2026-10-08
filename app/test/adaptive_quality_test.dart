import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/adaptive_quality.dart';

QualityTier _tier(String key, int mbit, {int height = 1080}) => QualityTier(
      key: key,
      label: '$key · $mbit Mbit/s',
      height: height,
      bitrateBps: mbit * 1000000,
    );

/// Une échelle comme le serveur la publie pour une source 1080p (ADR-0022).
final _ladder = [
  _tier('1080p-10m', 10),
  _tier('1080p', 6),
  _tier('1080p-4m', 4),
  _tier('720p', 3, height: 720),
  _tier('1080p-2m', 2),
  _tier('480p', 1, height: 480),
];

void main() {
  final start = DateTime(2026, 10, 8, 21);
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  group('la preuve que la connexion ne suit pas', () {
    test('une coupure seule est un accroc, trois rapprochées accusent la ligne',
        () {
      final adaptive = AdaptiveQuality();
      expect(adaptive.noteStall(at(0)), isFalse);
      expect(adaptive.noteStall(at(40)), isFalse);
      expect(adaptive.noteStall(at(90)), isTrue);
    });

    test('des coupures espacées ne s’additionnent pas', () {
      final adaptive = AdaptiveQuality();
      expect(adaptive.noteStall(at(0)), isFalse);
      expect(adaptive.noteStall(at(100)), isFalse);
      // La première est sortie de la fenêtre de trois minutes.
      expect(adaptive.noteStall(at(200)), isFalse);
      expect(adaptive.noteStall(at(250)), isTrue);
    });

    test('le tampon vidé par une recherche n’accuse personne', () {
      final adaptive = AdaptiveQuality();
      for (final second in [0, 30, 60]) {
        adaptive.noteDisturbance(at(second));
        expect(adaptive.noteStall(at(second + 1)), isFalse);
      }
      // Passé le délai de grâce, une coupure compte à nouveau.
      expect(adaptive.noteStall(at(80)), isFalse);
      expect(adaptive.noteStall(at(100)), isFalse);
      expect(adaptive.noteStall(at(120)), isTrue);
    });

    test('après une descente, le nouveau barreau repart d’un compte vierge',
        () {
      final adaptive = AdaptiveQuality();
      adaptive
        ..noteStall(at(0))
        ..noteStall(at(20));
      expect(adaptive.noteStall(at(40)), isTrue);
      // Le chargement du nouveau barreau n'est pas une coupure.
      expect(adaptive.noteStall(at(45)), isFalse);
      expect(adaptive.noteStall(at(70)), isFalse);
      expect(adaptive.noteStall(at(90)), isFalse);
      expect(adaptive.noteStall(at(110)), isTrue);
    });

    test('un choix fait dans le menu l’emporte jusqu’à la fin de la lecture',
        () {
      final adaptive = AdaptiveQuality()..noteUserChoice();
      for (var second = 0; second < 300; second += 20) {
        expect(adaptive.noteStall(at(second)), isFalse);
      }
    });
  });

  group('le barreau à demander', () {
    QualityTier? stepDown({String? current, int? demand, int height = 1080}) =>
        AdaptiveQuality.stepDown(
          ladder: _ladder,
          currentKey: current,
          sourceHeight: height,
          demandBps: demand,
        );

    test('depuis un barreau, le premier qui demande nettement moins', () {
      // 70 % de 10 Mbit/s : 6 passe, pas un barreau à 8 ou 9.
      expect(stepDown(current: '1080p-10m')?.key, '1080p');
      expect(stepDown(current: '1080p')?.key, '1080p-4m');
      // 70 % de 4 Mbit/s : 3 est trop près, 2 passe.
      expect(stepDown(current: '1080p-4m')?.key, '1080p-2m');
    });

    test('en Direct Play, contre le débit que le fichier annonce', () {
      // Un remux à 40 Mbit/s : le haut de l'échelle est déjà un vrai remède.
      expect(stepDown(demand: 40000000)?.key, '1080p-10m');
      // Un fichier à 8 Mbit/s : rien au-dessus de 5,6.
      expect(stepDown(demand: 8000000)?.key, '1080p-4m');
    });

    test('en Direct Play sans débit connu, le barreau natif de la source', () {
      expect(stepDown()?.key, '1080p');
      expect(stepDown(height: 720)?.key, '720p');
    });

    test('au bas de l’échelle, il n’y a plus rien à demander', () {
      expect(stepDown(current: '480p'), isNull);
    });

    test('un serveur sans échelle ne propose rien', () {
      expect(
        AdaptiveQuality.stepDown(
            ladder: const [], currentKey: null, sourceHeight: 1080),
        isNull,
      );
    });

    test('l’ordre de l’échelle reçue ne change pas la réponse', () {
      expect(
        AdaptiveQuality.stepDown(
          ladder: _ladder.reversed.toList(),
          currentKey: '1080p-10m',
          sourceHeight: 1080,
        )?.key,
        '1080p',
      );
    });
  });
}
