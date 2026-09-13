import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/navigation/search_route_observer.dart';
import 'package:onyx/tv/tv_ui_scale.dart';

void main() {
  void setScreen(WidgetTester tester, Size logical) {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = logical * 2.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('une télé de 960 px logiques met la page en page sur 1280',
      (tester) async {
    setScreen(tester, const Size(960, 540));
    Size? seen;
    Size? laidOut;

    await tester.pumpWidget(MaterialApp(
      home: TvUiScale(
        child: LayoutBuilder(builder: (context, constraints) {
          seen = MediaQuery.sizeOf(context);
          laidOut = constraints.biggest;
          return const SizedBox.expand();
        }),
      ),
    ));

    expect(seen, const Size(1280, 720));
    expect(laidOut, const Size(1280, 720));
  });

  testWidgets('la page réduite reste cliquable au bon endroit', (tester) async {
    setScreen(tester, const Size(960, 540));
    var taps = 0;

    await tester.pumpWidget(MaterialApp(
      home: TvUiScale(
        child: Stack(
          children: [
            Positioned(
              left: 1100,
              top: 600,
              width: 100,
              height: 60,
              child: GestureDetector(
                key: const ValueKey('target'),
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    ));

    final rect = tester.getRect(find.byKey(const ValueKey('target')));
    // Dessinée aux trois quarts : 1100 → 825, 600 → 450.
    expect(rect.left, closeTo(825, 0.01));
    expect(rect.top, closeTo(450, 0.01));

    await tester.tap(find.byKey(const ValueKey('target')));
    expect(taps, 1);
  });

  testWidgets('un écran déjà assez large n’est pas touché', (tester) async {
    setScreen(tester, const Size(1920, 1080));
    Size? seen;

    await tester.pumpWidget(MaterialApp(
      home: TvUiScale(
        child: Builder(builder: (context) {
          seen = MediaQuery.sizeOf(context);
          return const SizedBox.expand();
        }),
      ),
    ));

    expect(seen, const Size(1920, 1080));
  });

  testWidgets('chaque page est réduite, sauf le lecteur', (tester) async {
    setScreen(tester, const Size(960, 540));
    final navigator = GlobalKey<NavigatorState>();
    final sizes = <String, Size>{};

    Widget probe(String name) => Builder(builder: (context) {
          sizes[name] = MediaQuery.sizeOf(context);
          return const SizedBox.expand();
        });

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(
        pageTransitionsTheme: PageTransitionsTheme(builders: {
          for (final platform in TargetPlatform.values)
            platform: const TvScaledPageTransitionsBuilder(),
        }),
      ),
      home: probe('home'),
    ));

    navigator.currentState!.push(MaterialPageRoute(
      settings: const RouteSettings(name: SearchRouteObserver.playerRouteName),
      builder: (_) => probe('player'),
    ));
    await tester.pumpAndSettle();

    expect(sizes['home'], const Size(1280, 720));
    expect(sizes['player'], const Size(960, 540),
        reason: 'la vidéo est une couche système que Flutter ne réduit pas');
  });
}
