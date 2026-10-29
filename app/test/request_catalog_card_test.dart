import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/screens/requests/widgets/request_media_card.dart';
import 'package:onyx/screens/requests/widgets/request_status_dot.dart';
import 'package:onyx/theme/lite_mode.dart';
import 'package:onyx/widgets/global/app_network_image.dart';
import 'package:onyx/widgets/global/staggered_entrance.dart';

/// La grille Demander reprend les cartes d'OnyxHub (affiche seule, pastille,
/// cartouche au survol) et doit tenir sur une petite TV : images à la taille
/// de leur place, cascade d'arrivée retirée en mode léger.

RequestMediaItem _item({
  RequestMediaStatus status = RequestMediaStatus.unknown,
  String? releaseDate = '2021-01-01',
}) =>
    RequestMediaItem(
      id: 1,
      mediaType: RequestMediaType.movie,
      title: 'Dune',
      overview: 'Un résumé.',
      posterPath: '/dune.jpg',
      backdropPath: null,
      releaseDate: releaseDate,
      rating: 8.1,
      status: status,
    );

void main() {
  group('en attente de sortie', () {
    final today = DateTime(2026, 10, 28);

    test('demandé et daté dans le futur', () {
      expect(
          _item(status: RequestMediaStatus.pending, releaseDate: '2027-03-01')
              .isAwaitingRelease(today),
          isTrue);
      expect(
          _item(
                  status: RequestMediaStatus.processing,
                  releaseDate: '2026-10-29')
              .isAwaitingRelease(today),
          isTrue);
    });

    test('ni sorti, ni sans date, ni sans demande', () {
      expect(
          _item(status: RequestMediaStatus.pending, releaseDate: '2026-10-28')
              .isAwaitingRelease(today),
          isFalse,
          reason: 'sorti aujourd’hui');
      expect(
          _item(status: RequestMediaStatus.pending, releaseDate: null)
              .isAwaitingRelease(today),
          isFalse);
      expect(
          _item(status: RequestMediaStatus.unknown, releaseDate: '2027-01-01')
              .isAwaitingRelease(today),
          isFalse,
          reason: 'personne ne l’a demandé');
    });
  });

  testWidgets('la carte est l’affiche seule, le titre lu par l’accessibilité',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 150,
          height: 225,
          child: RequestMediaCard(
              item: _item(status: RequestMediaStatus.available), onTap: () {}),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel(RegExp('^Dune')), findsWidgets);
    expect(find.byType(RequestStatusDot), findsOneWidget);
    // Le cartouche (titre, type, résumé) n'est pas peint au repos.
    final details = tester.widget<AnimatedOpacity>(find
        .ancestor(
            of: find.text('Un résumé.'), matching: find.byType(AnimatedOpacity))
        .first);
    expect(details.opacity, 0);
  });

  testWidgets('une affiche TMDB se télécharge à la taille de sa place',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: AppNetworkImage(
          url: 'https://image.tmdb.org/t/p/w500/dune.jpg',
          width: 150,
          height: 225,
        ),
      ),
    ));

    final image =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.imageUrl, 'https://image.tmdb.org/t/p/w154/dune.jpg');
    // La source est plus étroite que le décodage arrondi : décodée telle quelle.
    expect(image.memCacheWidth, isNull);
  });

  group('cascade d’arrivée', () {
    Widget grid({bool lite = false}) => LiteScope(
          isLite: lite,
          child: MaterialApp(
            home: StaggeredEntranceScope(
              playKey: 'all',
              maxAnimated: 4,
              child: ListView(
                children: [
                  for (var i = 0; i < 6; i++)
                    StaggeredEntrance(
                      index: i,
                      child: SizedBox(height: 40, child: Text('carte $i')),
                    ),
                ],
              ),
            ),
          ),
        );

    double opacityOf(WidgetTester tester, String label) {
      final opacity =
          find.ancestor(of: find.text(label), matching: find.byType(Opacity));
      if (opacity.evaluate().isEmpty) return 1;
      return tester.widget<Opacity>(opacity.first).opacity;
    }

    testWidgets('les premières cartes montent l’une après l’autre',
        (tester) async {
      await tester.pumpWidget(grid());
      expect(opacityOf(tester, 'carte 0'), 0);
      await tester.pump(const Duration(milliseconds: 120));
      expect(opacityOf(tester, 'carte 0'),
          greaterThan(opacityOf(tester, 'carte 3')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(opacityOf(tester, 'carte $i'), 1);
      }
      // Au-delà des premières cartes, rien n'est enveloppé.
      expect(
          find.ancestor(
              of: find.text('carte 5'), matching: find.byType(Opacity)),
          findsNothing);
    });

    testWidgets('en mode léger, tout est là dès la première image',
        (tester) async {
      await tester.pumpWidget(grid(lite: true));
      expect(opacityOf(tester, 'carte 0'), 1);
      expect(opacityOf(tester, 'carte 3'), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
