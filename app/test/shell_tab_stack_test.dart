import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/shell/shell_tab_stack.dart';

/// Un onglet qui dit si ses animations ont le droit de tourner.
class _TickerProbe extends StatelessWidget {
  const _TickerProbe(this.log, this.name);

  final Map<String, bool> log;
  final String name;

  @override
  Widget build(BuildContext context) {
    log[name] = TickerMode.valuesOf(context).enabled;
    return const SizedBox.expand();
  }
}

Widget _stack(int selected, Map<String, bool> log) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ShellTabStack(
      selectedIndex: selected,
      mounted: const {0, 1},
      tabs: [_TickerProbe(log, 'home'), _TickerProbe(log, 'requests')],
    ),
  );
}

void main() {
  // Un indicateur de chargement dans un onglet caché demandait une image à
  // chaque rafraîchissement de l'écran : l'app au repos chauffait le Mac.
  testWidgets('les animations des onglets cachés sont suspendues',
      (tester) async {
    final log = <String, bool>{};
    await tester.pumpWidget(_stack(0, log));
    expect(log, {'home': true, 'requests': false});

    await tester.pumpWidget(_stack(1, log));
    expect(log, {'home': false, 'requests': true});
  });

  testWidgets('un spinner dans un onglet caché ne programme plus d\'image',
      (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTabStack(
        selectedIndex: 0,
        mounted: {0, 1},
        tabs: [
          SizedBox.expand(),
          Center(child: CircularProgressIndicator()),
        ],
      ),
    ));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('un onglet pas encore monté reste vide', (tester) async {
    final log = <String, bool>{};
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTabStack(
        selectedIndex: 0,
        mounted: const {0},
        tabs: [_TickerProbe(log, 'home'), _TickerProbe(log, 'requests')],
      ),
    ));
    expect(log.keys, ['home']);
  });
}
