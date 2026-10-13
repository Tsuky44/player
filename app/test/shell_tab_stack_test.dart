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

Widget _stack(String selected, Map<String, bool> log) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ShellTabStack(
      selected: selected,
      mounted: const {'home', 'requests'},
      tabs: {
        'home': _TickerProbe(log, 'home'),
        'requests': _TickerProbe(log, 'requests'),
      },
    ),
  );
}

/// Un onglet qui compte ses créations d'état : une de plus, et il a perdu sa
/// position de défilement, son tri et ses requêtes en cours.
class _Stateful extends StatefulWidget {
  const _Stateful(this.created, this.name);

  final List<String> created;
  final String name;

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  @override
  void initState() {
    super.initState();
    widget.created.add(widget.name);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  // Un indicateur de chargement dans un onglet caché demandait une image à
  // chaque rafraîchissement de l'écran : l'app au repos chauffait le Mac.
  testWidgets('les animations des onglets cachés sont suspendues',
      (tester) async {
    final log = <String, bool>{};
    await tester.pumpWidget(_stack('home', log));
    expect(log, {'home': true, 'requests': false});

    await tester.pumpWidget(_stack('requests', log));
    expect(log, {'home': false, 'requests': true});
  });

  testWidgets('un spinner dans un onglet caché ne programme plus d\'image',
      (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTabStack(
        selected: 'home',
        mounted: {'home', 'requests'},
        tabs: {
          'home': SizedBox.expand(),
          'requests': Center(child: CircularProgressIndicator()),
        },
      ),
    ));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('un onglet pas encore monté reste vide', (tester) async {
    final log = <String, bool>{};
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ShellTabStack(
        selected: 'home',
        mounted: const {'home'},
        tabs: {
          'home': _TickerProbe(log, 'home'),
          'requests': _TickerProbe(log, 'requests'),
        },
      ),
    ));
    expect(log.keys, ['home']);
  });

  // Les bibliothèques sont celles du serveur (ADR-0058) : en ajouter une
  // glisse un onglet au milieu des autres.
  testWidgets('une bibliothèque ajoutée ne remonte pas les onglets voisins',
      (tester) async {
    final created = <String>[];
    Widget stack(List<String> ids) => Directionality(
          textDirection: TextDirection.ltr,
          child: ShellTabStack(
            selected: 'requests',
            mounted: ids.toSet(),
            tabs: {for (final id in ids) id: _Stateful(created, id)},
          ),
        );

    await tester.pumpWidget(stack(['home', 'library:1', 'requests']));
    expect(created, ['home', 'library:1', 'requests']);

    await tester
        .pumpWidget(stack(['home', 'library:1', 'library:2', 'requests']));
    expect(created, ['home', 'library:1', 'requests', 'library:2']);

    await tester.pumpWidget(stack(['home', 'library:2', 'requests']));
    expect(created, hasLength(4), reason: 'aucun onglet restant ne renaît');
  });

  testWidgets('un onglet sélectionné qui n’existe plus rend l’accueil',
      (tester) async {
    final log = <String, bool>{};
    await tester.pumpWidget(_stack('library:9', log));
    expect(log, {'home': true, 'requests': false});
  });
}
