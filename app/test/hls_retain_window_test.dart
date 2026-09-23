import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/hls_retain_window.dart';
import 'package:onyx/services/hls_session.dart';

void main() {
  test('sans fenêtre annoncée, toute la session reste joignable', () {
    expect(
      retainedFloorSeconds(
          startOffset: 600, bufferedEnd: 9000, retainSeconds: null),
      600,
    );
  });

  test('reculer au-delà de ce que le serveur garde demande une session', () {
    // 30 minutes gardées derrière 2 h 30 de tampon, avec une minute de marge.
    expect(
      retainedFloorSeconds(
          startOffset: 0, bufferedEnd: 9000, retainSeconds: 1800),
      9000 - 1800 + 60,
    );
  });

  test('jamais avant le début de la session', () {
    expect(
      retainedFloorSeconds(
          startOffset: 1200, bufferedEnd: 1500, retainSeconds: 1800),
      1200,
    );
  });

  test('la fenêtre est lue depuis la réponse de /start', () {
    expect(
      HlsSession.fromJson(
              {'session_id': 's', 'master_url': 'm', 'retain_seconds': 1800})
          .retainSeconds,
      1800,
    );
    expect(
        HlsSession.fromJson({'session_id': 's', 'master_url': 'm'})
            .retainSeconds,
        isNull);
  });
}
