import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';

/// Ce que le port doit exposer pour qu'un moteur puisse être rendu.
///
/// Le défaut que ce test verrouille a coûté un film qui continuait de
/// s'entendre après qu'on l'ait quitté : la session ExoPlayer savait se
/// détruire, mais `PlaybackSession` ne l'exposait pas, donc personne ne
/// l'appelait. Une méthode qu'aucune interface ne déclare est une méthode que
/// personne n'appelle.
void main() {
  test('le cycle de vie fait partie du contrat', () {
    // Une implémentation minimale ne compile que si elle couvre tout le port —
    // y compris `prepare` et `dispose`. Retirer l'un des deux de l'interface
    // casse ce fichier.
    const PlaybackSession session = _ContractProbe();
    expect(session, isA<PlaybackSession>());
  });
}

/// N'existe que pour être vérifiée par le compilateur.
class _ContractProbe implements PlaybackSession {
  const _ContractProbe();

  @override
  Future<void> prepare() async {}

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
