import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/on_screen.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.log);

  final List<bool> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with OnScreenState {
  @override
  void didChangeOnScreen(bool onScreen) => widget.log.add(onScreen);

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Widget _host(List<bool> log, {required bool tickers}) =>
    TickerMode(enabled: tickers, child: _Probe(log));

void main() {
  tearDown(() => AppForeground.debugSetVisible(true));

  // Une minuterie de fond ne tourne que quand on voit son widget : l'accueil
  // sous le lecteur sondait encore le serveur toutes les dix secondes.
  testWidgets('démarre à l\'apparition, s\'arrête quand la page est cachée',
      (tester) async {
    final log = <bool>[];
    await tester.pumpWidget(_host(log, tickers: true));
    expect(log, [true]);

    await tester.pumpWidget(_host(log, tickers: false));
    expect(log, [true, false]);

    await tester.pumpWidget(_host(log, tickers: true));
    expect(log, [true, false, true]);
  });

  testWidgets('une page recouverte par une autre s\'arrête, et repart au retour',
      (tester) async {
    final log = <bool>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(WidgetsApp(
      navigatorKey: navigator,
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(settings, builder) =>
          PageRouteBuilder<T>(pageBuilder: (context, _, __) => builder(context)),
      home: _Probe(log),
    ));
    expect(log, [true]);

    navigator.currentState!.push(PageRouteBuilder<void>(
      pageBuilder: (context, _, __) => const SizedBox(),
    ));
    await tester.pumpAndSettle();
    expect(log, [true, false]);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(log, [true, false, true]);
  });

  testWidgets('une page cachée dès le départ ne démarre rien', (tester) async {
    final log = <bool>[];
    await tester.pumpWidget(_host(log, tickers: false));
    expect(log, isEmpty);
  });

  testWidgets('la fenêtre réduite arrête le travail, son retour le reprend',
      (tester) async {
    final log = <bool>[];
    await tester.pumpWidget(_host(log, tickers: true));

    AppForeground.debugSetVisible(false);
    expect(log, [true, false]);

    AppForeground.debugSetVisible(true);
    expect(log, [true, false, true]);
  });

  testWidgets('le passage au premier plan suit le cycle de vie de l\'app',
      (tester) async {
    final log = <bool>[];
    await tester.pumpWidget(_host(log, tickers: true));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(log, [true], reason: 'sans le focus, la fenêtre reste visible');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(log, [true, false]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(log, [true, false, true]);
  });
}
