import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/interface_tour_storage.dart';
import 'package:onyx/tv/tv_mode.dart';
import 'package:onyx/widgets/global/interface_tour/interface_tour.dart';
import 'package:onyx/widgets/global/interface_tour/tour_anchor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Une coquille en miniature : trois zones sur les cinq — ce compte n'a ni
/// demandes ni téléchargements — et un bouton qui lance la présentation.
class _Shell extends StatelessWidget {
  const _Shell({required this.anchors, required this.onDone});

  final TourAnchors anchors;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return TourAnchorScope(
      anchors: anchors,
      child: Scaffold(
        body: Column(
          children: [
            const Row(
              children: [
                TourTarget(
                  anchor: TourAnchor.library,
                  child: SizedBox(width: 220, height: 40, child: Text('tabs')),
                ),
                Spacer(),
                TourTarget(
                  anchor: TourAnchor.search,
                  child: SizedBox(width: 200, height: 34),
                ),
                TourTarget(
                  anchor: TourAnchor.account,
                  child: SizedBox(key: Key('account'), width: 44, height: 44),
                ),
              ],
            ),
            const Spacer(),
            Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showInterfaceTour(context, anchors: anchors).then((_) {
                  onDone();
                }),
                child: const Text('lancer'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  late int done;

  Future<void> open(WidgetTester tester, {bool tv = false}) async {
    done = 0;
    await tester.pumpWidget(TvScope(
      isTv: tv,
      child: MaterialApp(
        home: _Shell(anchors: TourAnchors(), onDone: () => done++),
      ),
    ));
    await tester.tap(find.text('lancer'));
    await tester.pumpAndSettle();
  }

  testWidgets('la présentation ne compte que les zones que l’écran montre',
      (tester) async {
    await open(tester);

    // Accueil, médiathèque, recherche, compte : ni demandes ni hors ligne.
    expect(find.text('Bienvenue sur Onyx'), findsOneWidget);
    expect(find.text('Étape 1 sur 4'), findsOneWidget);
    // Rien à grossir tant qu'on ne montre aucune zone.
    expect(find.byType(RawMagnifier), findsNothing);
  });

  testWidgets('un appui n’importe où passe à la suite, loupe sur la zone',
      (tester) async {
    await open(tester);

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(find.text('Votre médiathèque'), findsOneWidget);
    expect(find.text('Étape 2 sur 4'), findsOneWidget);
    final lens = tester.getRect(find.byType(RawMagnifier));
    expect(lens.contains(const Offset(110, 20)), isTrue,
        reason: 'la loupe se pose sur les onglets');

    await tester.tapAt(const Offset(400, 300));
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(find.text('Votre compte'), findsOneWidget);
    final account = tester.getRect(find.byKey(const Key('account')));
    final onAccount = tester.getRect(find.byType(RawMagnifier));
    expect(onAccount.overlaps(account), isTrue);
    // Collée au bord droit, la loupe reste dans l'écran.
    expect(onAccount.right, lessThanOrEqualTo(800));
  });

  testWidgets('« Passer » ferme la présentation à n’importe quelle étape',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Suivant'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Passer'));
    await tester.pumpAndSettle();

    expect(find.text('Votre médiathèque'), findsNothing);
    expect(done, 1);
  });

  testWidgets('la dernière étape se termine, et ne propose plus de passer',
      (tester) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Suivant'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Passer'), findsNothing);
    await tester.tap(find.text('Terminer'));
    await tester.pumpAndSettle();

    expect(find.text('Votre compte'), findsNothing);
    expect(done, 1);
  });

  testWidgets('à la télécommande : OK avance, Retour passe', (tester) async {
    await open(tester, tv: true);

    // « Suivant » a le focus d'emblée : rien à viser avant d'appuyer.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Votre médiathèque'), findsOneWidget);

    // Et il le garde d'une étape à l'autre.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Recherche'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Recherche'), findsNothing);
    expect(done, 1);
  });

  testWidgets('sous « réduire les animations », la loupe arrive sans trajet',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await open(tester);

    await tester.tap(find.text('Suivant'));
    await tester.pump();
    final arrived = tester.getRect(find.byType(RawMagnifier));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(RawMagnifier)), arrived);
  });

  testWidgets('chaque commande de la présentation a un nom', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.tap(find.text('Suivant'));
    await tester.pumpAndSettle();

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('une rangée de l’accueil sous l’écran est amenée avant la loupe',
      (tester) async {
    final anchors = TourAnchors();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: TourAnchorScope(
        anchors: anchors,
        child: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showInterfaceTour(context, anchors: anchors),
                  child: const Text('lancer'),
                ),
              ),
              // À cheval sur le bas de l'écran, comme la première rangée sous
              // le bandeau : construite, mais pas entièrement visible.
              const SizedBox(height: 500),
              const TourTarget(
                anchor: TourAnchor.resume,
                child: SizedBox(height: 200, child: Text('reprendre')),
              ),
              const SizedBox(height: 900),
            ],
          ),
        ),
      ),
    ));
    await tester.tap(find.text('lancer'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Suivant'));
    await tester.pumpAndSettle();

    expect(find.text('Reprendre la lecture'), findsOneWidget);
    expect(scroll.offset, greaterThan(0));
    final row = tester.getRect(find.text('reprendre'));
    expect(row.bottom, lessThanOrEqualTo(600));
    expect(tester.getRect(find.byType(RawMagnifier)).overlaps(row), isTrue);
  });

  test('« Revoir la présentation » prévient qui écoute', () {
    var requests = 0;
    void listener() => requests++;
    InterfaceTourReplay.requests.addListener(listener);
    addTearDown(() => InterfaceTourReplay.requests.removeListener(listener));

    InterfaceTourReplay.request();

    expect(requests, 1);
  });

  test('la présentation est retenue par compte', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await InterfaceTourStorage.hasSeen('a'), isFalse);
    await InterfaceTourStorage.markSeen('a');

    expect(await InterfaceTourStorage.hasSeen('a'), isTrue);
    // Une autre personne sur le même appareil n'a encore rien vu.
    expect(await InterfaceTourStorage.hasSeen('b'), isFalse);
  });
}
