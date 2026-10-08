import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/watched_verdict.dart';

void main() {
  test('un média compte comme vu à partir de 90 %', () {
    expect(countsAsWatched(positionSeconds: 899, durationSeconds: 1000),
        isFalse);
    expect(
        countsAsWatched(positionSeconds: 900, durationSeconds: 1000), isTrue);
  });

  // Un animé de 24 min dont le générique commence à 20 min 30 : l'enchaînement
  // automatique le quitte à 85 %, et l'épisode restait « en cours ».
  test('un épisode quitté pendant son générique de fin compte comme vu', () {
    expect(
      countsAsWatched(
        positionSeconds: 1235,
        durationSeconds: 1440,
        leftDuringCredits: true,
      ),
      isTrue,
    );
    expect(
        countsAsWatched(positionSeconds: 1235, durationSeconds: 1440), isFalse);
  });

  // Une détection d'outro posée à tort au milieu de l'épisode : le quitter là
  // le marquait vu et faisait perdre la reprise.
  test('un générique annoncé sous le plancher ne décide de rien', () {
    expect(
      countsAsWatched(
        positionSeconds: 600,
        durationSeconds: 1440,
        leftDuringCredits: true,
      ),
      isFalse,
    );
    expect(
      countsAsWatched(
        positionSeconds: 1008,
        durationSeconds: 1440,
        leftDuringCredits: true,
      ),
      isTrue,
      reason: '70 % pile : le plancher est inclus',
    );
  });

  test('sans durée, rien ne permet de dire que le média a été vu', () {
    expect(
      countsAsWatched(
          positionSeconds: 1235, durationSeconds: 0, leftDuringCredits: true),
      isFalse,
    );
    expect(countsAsWatched(positionSeconds: 1235, durationSeconds: 0), isFalse);
  });

  test('une lecture jamais commencée n\'a rien vu', () {
    expect(
      countsAsWatched(
          positionSeconds: 0, durationSeconds: 1440, leftDuringCredits: true),
      isFalse,
    );
  });
}
