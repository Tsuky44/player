import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/on_screen.dart';
import 'package:onyx/widgets/global/live_progress_state.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.refreshes);

  final List<String> refreshes;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with OnScreenState, LiveProgressState {
  @override
  void onProgressChanged() => widget.refreshes.add('relu');

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Widget _host(List<String> refreshes, {required bool visible}) =>
    TickerMode(enabled: visible, child: _Probe(refreshes));

void main() {
  tearDown(() => AppForeground.debugSetVisible(true));

  // Aucun serveur ici : le sondeur échoue, et c'est le cas qui compte — un
  // retour à l'écran doit relire même quand le jeton est introuvable.
  testWidgets(
      'la première apparition laisse l\'écran charger seul, chaque retour '
      'le fait relire', (tester) async {
    final refreshes = <String>[];
    await tester.pumpWidget(_host(refreshes, visible: true));
    await tester.pump();
    expect(refreshes, isEmpty);

    // Le lecteur recouvre l'écran, puis on le quitte.
    await tester.pumpWidget(_host(refreshes, visible: false));
    await tester.pump();
    expect(refreshes, isEmpty);

    await tester.pumpWidget(_host(refreshes, visible: true));
    await tester.pump();
    expect(refreshes, ['relu']);

    // L'app passe en arrière-plan et revient.
    AppForeground.debugSetVisible(false);
    AppForeground.debugSetVisible(true);
    await tester.pump();
    expect(refreshes, ['relu', 'relu']);
  });
}
