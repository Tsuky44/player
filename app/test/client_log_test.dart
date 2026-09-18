import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/client_log.dart';

void main() {
  setUp(ClientLog.resetForTest);

  test('capture ce que le code écrit déjà, sans que le site d’appel change', () {
    ClientLog.install();
    debugPrint('Player: asking 1080p from 0s');

    expect(ClientLog.entries.single.message, 'Player: asking 1080p from 0s');
    expect(ClientLog.entries.single.level, LogLevel.info);
  });

  test('une erreur est une erreur parce qu’elle est écrite comme telle', () {
    ClientLog.install();
    // Le texte ne contient aucun des mots qu'un classement par mot-clé
    // chercherait : c'est le point.
    ClientLog.error('ExoPlayer: PlaybackFailure(source, 404)');
    debugPrint('Playback: 1920x1080 h264 — failed nothing at all');

    final errors =
        ClientLog.entries.where((e) => e.level == LogLevel.error).toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('PlaybackFailure'));
  });

  test('n’enregistre pas deux fois une erreur qui passe aussi par la console', () {
    ClientLog.install();
    ClientLog.error('API Error [GET] /stream: badResponse (401)');

    expect(ClientLog.entries, hasLength(1));
  });

  test('garde les dernières lignes, pas les premières', () {
    ClientLog.install();
    for (var i = 0; i < ClientLog.capacity + 50; i++) {
      debugPrint('ligne $i');
    }

    expect(ClientLog.entries, hasLength(ClientLog.capacity));
    expect(ClientLog.entries.first.message, 'ligne 50');
    expect(ClientLog.entries.last.message,
        'ligne ${ClientLog.capacity + 49}');
  });

  test('tronque une ligne démesurée plutôt que de remplir le tampon avec', () {
    ClientLog.install();
    debugPrint('x' * (ClientLog.maxMessageLength * 3));

    expect(ClientLog.entries.single.message.length,
        ClientLog.maxMessageLength + 1); // le caractère de troncature
  });

  test('l’export dit de quelle app et de quel appareil il vient', () {
    ClientLog.install();
    ClientLog.error('une panne');
    debugPrint('une ligne ordinaire');

    expect(ClientLog.export(), contains('une ligne ordinaire'));
    expect(ClientLog.export(errorsOnly: true), contains('une panne'));
    expect(ClientLog.export(errorsOnly: true),
        isNot(contains('une ligne ordinaire')));
    // L'entête, sans quoi un journal collé ailleurs oblige à redemander la
    // version et l'appareil.
    expect(ClientLog.export(), startsWith('Onyx '));
  });

  test('vider laisse le journal utilisable', () {
    ClientLog.install();
    debugPrint('avant');
    ClientLog.clear();
    debugPrint('après');

    expect(ClientLog.entries.single.message, 'après');
  });
}
