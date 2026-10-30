import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/theme/lite_mode.dart';
import 'package:onyx/widgets/global/poster_flight.dart';

/// L'envol d'une affiche vers sa fiche : une route, une horloge, la fiche
/// cachée jusqu'à l'atterrissage et jamais reconstruite en route.

int _builds = 0;

class _Page extends StatefulWidget {
  const _Page();

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    _builds++;
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: FlightDrop(child: Text('Fiche'))),
      );
}

PosterFlightRoute<void> _route({bool lite = false}) => PosterFlightRoute<void>(
      from: const Rect.fromLTWH(40, 60, 120, 180),
      radius: 12,
      posterUrl: null,
      backdropUrl: 'https://image.tmdb.org/t/p/original/x.jpg',
      backdropHeight: 300,
      lite: lite,
      builder: (_) => const _Page(),
    );

Future<NavigatorState> _pump(WidgetTester tester) async {
  _builds = 0;
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: key,
    home: const Scaffold(body: Text('Catalogue')),
  ));
  return key.currentState!;
}

void main() {
  setUp(() => LiteMode.enabled.value = false);

  testWidgets('la fiche est cachée jusqu’à l’atterrissage, puis posée',
      (tester) async {
    final nav = await _pump(tester);
    nav.push(_route());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // En plein retournement : la fiche existe mais ne se montre pas.
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);

    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 1);

    await tester.pumpAndSettle();
    expect(find.text('Fiche'), findsOneWidget);
  });

  testWidgets('la fiche n’est construite qu’une fois, de l’envol à la pose',
      (tester) async {
    final nav = await _pump(tester);
    nav.push(_route());
    await tester.pumpAndSettle();

    expect(_builds, 1);
  });

  testWidgets('la page quittée reste visible pendant l’envol, hors écran après',
      (tester) async {
    final nav = await _pump(tester);
    nav.push(_route());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Catalogue'), findsOneWidget);

    await tester.pumpAndSettle();
    // La route est opaque : l’ancienne page n’est plus peinte.
    expect(find.text('Catalogue'), findsNothing);
  });

  testWidgets('l’envol ne touche pas aux pointeurs de la fiche avant la pose',
      (tester) async {
    final nav = await _pump(tester);
    nav.push(_route());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final ignoring = tester
        .widgetList<IgnorePointer>(find.byType(IgnorePointer))
        .any((w) => w.ignoring);
    expect(ignoring, isTrue);
  });

  testWidgets('en mode léger, l’envol est plus court et sans retournement',
      (tester) async {
    final full = _route();
    final lite = _route(lite: true);
    expect(lite.transitionDuration, lessThan(full.transitionDuration));
    expect(lite.reverseTransitionDuration, Duration.zero);

    final nav = await _pump(tester);
    nav.push(lite);
    await tester.pumpAndSettle();
    expect(find.text('Fiche'), findsOneWidget);
  });

  testWidgets('revenir en arrière ne rejoue pas l’envol', (tester) async {
    final nav = await _pump(tester);
    nav.push(_route());
    await tester.pumpAndSettle();

    nav.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Un fondu bref, pas la carte qui revole.
    expect(find.text('Catalogue'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Fiche'), findsNothing);
  });

  testWidgets('FlightDrop pose son enfant tel quel hors envol', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: FlightDrop(child: Text('Titre')),
    ));
    expect(find.text('Titre'), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
  });
}
