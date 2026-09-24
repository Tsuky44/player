import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/shell/shell_page_open_listener.dart';

/// La coquille en miniature : un navigateur à pages qui reçoit une nouvelle
/// page d'onglets à chaque reconstruction, comme `MainShell`.
class _Shell extends StatefulWidget {
  const _Shell({required this.navigatorKey, required this.builds});

  final GlobalKey<NavigatorState> navigatorKey;
  final List<bool> builds;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool _pageOpen = false;

  @override
  Widget build(BuildContext context) {
    widget.builds.add(_pageOpen);
    return MaterialApp(
      home: ShellPageOpenListener(
        navigatorKey: widget.navigatorKey,
        pageOpen: _pageOpen,
        onPageOpenChanged: (open) => setState(() => _pageOpen = open),
        child: Navigator(
          key: widget.navigatorKey,
          // Une liste et une page neuves à chaque fois, comme `MainShell`.
          pages: [
            MaterialPage<void>(
              key: const ValueKey('tabs'),
              child: Text('onglets ${widget.builds.length}'),
            ),
          ],
          onDidRemovePage: (_) {},
        ),
      ),
    );
  }
}

void main() {
  // Une mise à jour des pages vide puis remplit l'historique, et chaque étape
  // envoie sa notification : `false`, `false`, puis `true`. Lues telles
  // quelles, elles faisaient reconstruire la coquille à chaque frame tant
  // qu'une fiche était ouverte, y compris sous le lecteur.
  testWidgets(
      'une fiche ouverte ne fait reconstruire la coquille qu’une fois',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final builds = <bool>[];
    await tester.pumpWidget(_Shell(navigatorKey: navigatorKey, builds: builds));

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('fiche')),
    );
    // Avec la boucle, les frames ne s'arrêtent jamais et pumpAndSettle expire.
    await tester.pumpAndSettle();
    expect(builds, [false, true]);

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds, [false, true], reason: 'la coquille reste au repos');

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(builds, [false, true, false]);
  });
}
