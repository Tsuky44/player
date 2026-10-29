import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/screens/requests/widgets/request_detail_hero.dart';
import 'package:onyx/screens/requests/widgets/request_status_badge.dart';
import 'package:onyx/screens/requests/widgets/request_status_motion.dart';
import 'package:onyx/theme/lite_mode.dart';

/// La fiche de demande reprend l'en-tête d'OnyxHub : surtitre de statut en
/// capitales, pastilles d'action arrondies. Un statut se lit sans être une
/// action, et ce qui tourne sans fin disparaît en mode léger.
void main() {
  Widget host(Widget child, {bool lite = false}) => LiteScope(
        isLite: lite,
        child: MaterialApp(home: Scaffold(body: Center(child: child))),
      );

  testWidgets('le surtitre dit « en attente de sortie » pour un titre à venir',
      (tester) async {
    await tester.pumpWidget(host(const RequestAvailabilityBadge(
      status: RequestMediaStatus.pending,
      awaitingRelease: true,
    )));
    expect(find.text('DEMANDÉ · EN ATTENTE DE SORTIE'), findsOneWidget);

    await tester.pumpWidget(host(const RequestAvailabilityBadge(
      status: RequestMediaStatus.processing,
    )));
    expect(find.text('DEMANDÉ'), findsOneWidget);
  });

  testWidgets('une pastille de statut ne prend pas le focus de la télécommande',
      (tester) async {
    await tester.pumpWidget(host(const HeroPill(
      label: 'Disponible',
      style: HeroPillStyle.status,
    )));
    final inkWell = tester.widget<InkWell>(find.byType(InkWell));
    expect(inkWell.canRequestFocus, isFalse);

    await tester.pumpWidget(host(HeroPill(
      label: 'Demander',
      style: HeroPillStyle.glass,
      onPressed: () {},
    )));
    expect(
        tester.widget<InkWell>(find.byType(InkWell)).canRequestFocus, isTrue);
  });

  testWidgets('« En cours » court sous la pastille, sauf en mode léger',
      (tester) async {
    const pill = HeroPill(
      label: 'En cours de traitement',
      style: HeroPillStyle.status,
      track: true,
    );
    await tester.pumpWidget(host(pill));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(host(pill, lite: true));
    expect(find.byType(StatusTrack), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('le faisceau de « Disponible » passe une fois puis s’en va',
      (tester) async {
    await tester.pumpWidget(host(const HeroPill(
      label: 'Disponible',
      style: HeroPillStyle.status,
      beam: true,
    )));
    expect(find.byType(SlideTransition), findsWidgets);
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(StatusBeam),
            matching: find.byType(SlideTransition)),
        findsNothing);
  });
}
