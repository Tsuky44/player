// Le sujet du test est print lui-même.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/detached_output.dart';

void main() {
  /// Lance [DetachedOutput.run] sous une zone qui capte ce qui atteint
  /// vraiment `print`, c'est-à-dire ce que le moteur recopierait.
  Future<List<String>> printedBy(List<String> args) async {
    final reached = <String>[];
    final done = Completer<void>();
    runZoned(
      () => DetachedOutput.run(args, () async {
        print('trace mpv ● ○');
        await Future<void>.delayed(Duration.zero);
        print('après une attente');
        done.complete();
      }),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => reached.add(line),
      ),
    );
    await done.future;
    return reached;
  }

  test('sans sortie standard, aucun print n’atteint le moteur', () async {
    expect(await printedBy([DetachedOutput.flag]), isEmpty);
  });

  test('avec une sortie standard, print passe', () async {
    expect(await printedBy([]), ['trace mpv ● ○', 'après une attente']);
  });

  test('le runner Windows passe le même drapeau que l’app attend', () {
    final header = File('windows/runner/utils.h').readAsStringSync();
    expect(header, contains('kNoStdoutFlag[] = "${DetachedOutput.flag}"'),
        reason: 'Le runner signale l’absence de console avec ce drapeau : '
            's’ils divergent, l’app ne coupe plus print et plante au '
            'lancement d’un média (0xc0000409).');
  });
}
