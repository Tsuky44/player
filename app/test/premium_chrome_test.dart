import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/navigation/search_route_observer.dart';
import 'package:onyx/screens/shell/mobile_bottom_nav.dart';
import 'package:onyx/screens/shell/mobile_top_bar.dart';
import 'package:onyx/theme/app_icons.dart';
import 'package:onyx/theme/app_page_transitions.dart';
import 'package:onyx/widgets/global/glass_chrome.dart';
import 'package:onyx/widgets/global/onyx_wordmark.dart';

Widget _app(Widget child, {Size size = const Size(1280, 800)}) {
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

void main() {
  group('onglets du header desktop', () {
    double indicatorWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('nav-tab-indicator'))).width;

    testWidgets('l’onglet affiché porte un trait dessous, pas une pilule', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(GlassNavTab(label: 'Films', selected: true, onTap: () {})),
      );
      await tester.pumpAndSettle();
      expect(indicatorWidth(tester), 16);

      final pill = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer).first,
      );
      final decoration = pill.decoration! as BoxDecoration;
      expect(decoration.color, Colors.transparent);
    });

    testWidgets('un onglet non affiché n’a pas de trait', (tester) async {
      await tester.pumpWidget(
        _app(GlassNavTab(label: 'Films', selected: false, onTap: () {})),
      );
      await tester.pumpAndSettle();
      expect(indicatorWidth(tester), 0);
    });
  });

  group('GlassIconButton', () {
    testWidgets('la cible atteint 44 px, le disque garde sa taille', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(GlassIconButton(size: 32, onTap: () {}, child: const SizedBox())),
      );
      expect(tester.getSize(find.byType(InkWell)), const Size(44, 44));
      final disc = find.descendant(
        of: find.byType(GlassIconButton),
        matching: find.byType(Container),
      );
      expect(tester.getSize(disc), const Size(32, 32));
    });

    testWidgets('48 px sur un téléphone', (tester) async {
      await tester.pumpWidget(
        _app(
          GlassIconButton(size: 32, onTap: () {}, child: const SizedBox()),
          size: const Size(390, 844),
        ),
      );
      expect(tester.getSize(find.byType(InkWell)), const Size(48, 48));
    });
  });

  group('ScrollEdgeListener', () {
    testWidgets('signale le départ du haut de page, puis le retour', (
      tester,
    ) async {
      final events = <bool>[];
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          ScrollEdgeListener(
            onScrolledChanged: events.add,
            child: ListView(
              controller: controller,
              children: [
                // Une rangée horizontale : elle défile sans que la page bouge.
                SizedBox(
                  height: 100,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: const [SizedBox(width: 3000)],
                  ),
                ),
                const SizedBox(height: 3000),
              ],
            ),
          ),
        ),
      );

      await tester.drag(find.byType(ListView).last, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(events, isEmpty);

      controller.jumpTo(200);
      await tester.pump();
      expect(events, [true]);

      controller.jumpTo(0);
      await tester.pump();
      expect(events, [true, false]);
    });
  });

  group('barre d’onglets mobile', () {
    testWidgets('l’onglet actif prend la variante pleine de son icône', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          MobileBottomNav(
            selectedIndex: 1,
            onTabSelected: (_) {},
            canRequestMedia: true,
            canDownload: true,
          ),
          size: const Size(390, 844),
        ),
      );
      expect(find.byIcon(AppIcons.movieSelected), findsOneWidget);
      expect(find.byIcon(AppIcons.movie), findsNothing);
      expect(find.byIcon(AppIcons.home), findsOneWidget);
    });
  });

  group('transition de page', () {
    const builder = OnyxPageTransitionsBuilder();

    Widget build(WidgetTester tester, {String? name, bool reduced = false}) {
      late Widget built;
      final route = MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox(),
      );
      return MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Builder(
          builder: (context) {
            built = builder.buildTransitions(
              route,
              context,
              const AlwaysStoppedAnimation(0.5),
              const AlwaysStoppedAnimation(0),
              const SizedBox(),
            );
            return built;
          },
        ),
      );
    }

    testWidgets('une fiche monte en fondu', (tester) async {
      await tester.pumpWidget(build(tester));
      expect(find.byType(SlideTransition), findsOneWidget);
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    testWidgets('le lecteur n’a qu’un fondu, jamais de géométrie', (
      tester,
    ) async {
      await tester.pumpWidget(
        build(tester, name: SearchRouteObserver.playerRouteName),
      );
      expect(find.byType(SlideTransition), findsNothing);
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    testWidgets('« réduire les animations » garde le fondu, pas la montée', (
      tester,
    ) async {
      await tester.pumpWidget(build(tester, reduced: true));
      expect(find.byType(SlideTransition), findsNothing);
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    test('la même transition partout, sauf le glissé natif d’iOS', () {
      final builders = appPageTransitionsTheme.builders;
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(builders[platform], isA<OnyxPageTransitionsBuilder>());
      }
      expect(
          builders[TargetPlatform.iOS], isA<CupertinoPageTransitionsBuilder>());
    });
  });

  testWidgets('le wordmark se lit « Onyx » et garde le ratio du dessin', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const OnyxWordmark(height: 20)));
    expect(find.bySemanticsLabel('Onyx'), findsOneWidget);
    expect(tester.getSize(find.byType(OnyxWordmark)), const Size(95, 20));
  });
}
