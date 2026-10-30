import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/my_request.dart';
import 'package:onyx/providers/media_requests_provider.dart';
import 'package:onyx/screens/requests/widgets/request_season_list.dart';
import 'package:onyx/screens/requests/widgets/season_liquid.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/theme/app_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fiche d'une demande : les saisons sont des bulles sur une seule ligne, comme
/// sur OnyxHub. Toucher l'une la gonfle en pilule et ouvre ses épisodes en
/// dessous, une seule à la fois.

class _Api extends ApiClient {
  final List<int> calls = [];

  // Le panneau d'une saison lit les droits du compte (ADR-0098) : sans cette
  // doublure, il appellerait un vrai serveur.
  @override
  Future<RequestAccess> getRequestAccess() async => RequestAccess.basic;

  @override
  Future<List<RequestEpisode>> getRequestSeasonEpisodes(
    int tmdbId,
    int seasonNumber,
  ) async {
    calls.add(seasonNumber);
    return [
      RequestEpisode(
        id: seasonNumber * 100,
        number: 1,
        name: 'Épisode pilote S$seasonNumber',
        overview: '',
        stillPath: null,
        airDate: null,
        runtime: 0,
        rating: 0,
      ),
    ];
  }
}

const _longName = 'Cyberpunk: Edgerunners 2, la saison au titre très long';

const _show = RequestMediaItem(
  id: 1,
  mediaType: RequestMediaType.tv,
  title: 'Série',
  overview: '',
  posterPath: null,
  backdropPath: null,
  releaseDate: null,
  rating: 0,
  status: RequestMediaStatus.unknown,
);

Future<_Api> _pump(WidgetTester tester) async {
  final api = _Api();
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => MediaRequestsProvider(api),
    child: const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RequestSeasonList(
            tmdbId: 1,
            showItem: _show,
            seasons: [
              RequestSeason(
                number: 1,
                name: 'Saison 1',
                episodeCount: 10,
                posterPath: null,
                status: RequestMediaStatus.unknown,
                airDate: '2021-03-04',
              ),
              RequestSeason(
                number: 2,
                name: 'Saison 2',
                episodeCount: 8,
                posterPath: null,
                status: RequestMediaStatus.available,
              ),
              RequestSeason(
                number: 3,
                name: _longName,
                episodeCount: 6,
                posterPath: null,
                status: RequestMediaStatus.partial,
                availableEpisodes: 4,
              ),
            ],
          ),
        ),
      ),
    ),
  ));
  return api;
}

/// La bulle d'une saison, retrouvée à son libellé d'accessibilité.
Finder _bubble(String label) => find.bySemanticsLabel(label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('les saisons sont des bulles rondes numérotées, épisodes repliés',
      (tester) async {
    await _pump(tester);

    for (final label in ['1', '2', '3']) {
      expect(find.text(label), findsOneWidget);
    }
    // Fermées, les bulles sont des ronds de même taille sur la même ligne.
    final one = tester.getRect(find.text('1'));
    final two = tester.getRect(find.text('2'));
    expect(one.center.dy, two.center.dy);
    expect(two.left, greaterThan(one.left));
    expect(
        tester.getSize(_bubble('Saison 1, 10 épisodes')), const Size(48, 48));
    expect(find.text('Saison 1'), findsNothing);
    expect(find.textContaining('Épisode pilote'), findsNothing);
  });

  testWidgets('la saison ouverte se gonfle en pilule et ouvre son en-tête',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();

    // La bulle s'est élargie : le nom et l'affiche prennent la place du nombre.
    expect(tester.getSize(_bubble('Saison 1, 10 épisodes')).width,
        greaterThan(48));
    // Nom, nombre d'épisodes et année : dans la bulle et dans l'en-tête.
    expect(find.text('Saison 1'), findsNWidgets(2));
    expect(find.text('10 épisodes · 2021'), findsNWidgets(2));
    // Une saison encore inconnue peut être demandée depuis son en-tête.
    expect(find.text('Demander'), findsOneWidget);
    expect(find.text('Épisode pilote S1'), findsOneWidget);
  });

  testWidgets('une saison disponible montre son statut au lieu de « Demander »',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();

    expect(find.text('Demander'), findsNothing);
    expect(find.text('Disponible'), findsOneWidget);
  });

  testWidgets(
      'un nom de saison long est coupé dans la bulle, entier dans l’en-tête',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(find.text(_longName), findsNWidgets(2));
    expect(tester.getSize(_bubble('$_longName, 6 épisodes')).width,
        lessThan(48 + 10 + 16 + 240 + 1));
  });

  testWidgets(
      'toucher une saison déroule ses épisodes, une autre remplace la première, '
      'retoucher la saison ouverte la replie', (tester) async {
    final api = await _pump(tester);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.text('Épisode pilote S1'), findsOneWidget);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();
    expect(find.text('Épisode pilote S1'), findsNothing);
    expect(find.text('Épisode pilote S2'), findsOneWidget);
    // La première bulle est redevenue un rond.
    expect(
        tester.getSize(_bubble('Saison 1, 10 épisodes')), const Size(48, 48));

    // Revenir à une saison déjà vue ne refait pas d'appel réseau.
    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.text('Épisode pilote S1'), findsOneWidget);
    expect(api.calls, [1, 2]);

    await tester.tap(_bubble('Saison 1, 10 épisodes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Épisode pilote'), findsNothing);
  });

  testWidgets('la lumière du panneau se pose sous la bulle ouverte',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();

    final bubble = tester.getRect(_bubble('Saison 2, 8 épisodes'));
    final line = find.byWidgetPredicate((w) =>
        w is Positioned && w.height == 1 && w.width == 176 && w.top == 0);
    final beam = tester.getRect(line);
    expect((beam.center.dx - bubble.center.dx).abs(), lessThan(1));
    expect(beam.top, greaterThan(bubble.bottom));
  });

  testWidgets('une saison à demander porte un « + » bleu, pas les autres',
      (tester) async {
    await _pump(tester);

    // Seule la saison 1 est inconnue : un seul « + » sur les bulles fermées.
    expect(find.byIcon(AppIcons.add), findsOneWidget);
  });

  testWidgets('une saison partielle dit combien d’épisodes restent à venir',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();

    expect(find.text('Partiellement disponible · 2 restants'), findsOneWidget);
  });

  test('les épisodes restants suivent le statut de la saison', () {
    RequestSeason season(RequestMediaStatus status, [int available = 0]) =>
        RequestSeason(
          number: 1,
          name: '',
          episodeCount: 10,
          posterPath: null,
          status: status,
          availableEpisodes: available,
        );

    expect(season(RequestMediaStatus.pending).remainingEpisodes, 10);
    expect(season(RequestMediaStatus.partial, 7).remainingEpisodes, 3);
    expect(season(RequestMediaStatus.available, 10).remainingEpisodes, isNull);
    expect(season(RequestMediaStatus.unknown).remainingEpisodes, isNull);
    expect(season(RequestMediaStatus.processing, 12).remainingEpisodes, isNull);
  });

  testWidgets(
      'changer de saison lâche une goutte, qui s’efface une fois la bulle éclairée',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2'));
    await tester.pump(const Duration(milliseconds: 150));

    // En route : la goutte est peinte, la bulle choisie ne montre pas encore
    // son nom.
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is SeasonDropPainter),
        findsOneWidget);

    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is SeasonDropPainter),
        findsNothing);
    expect(find.text('Saison 2'), findsNWidgets(2));
    expect(
        tester.getSize(_bubble('Saison 1, 10 épisodes')), const Size(48, 48));
  });

  testWidgets('sans animation, pas de goutte : la bulle s’ouvre d’emblée',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pump(tester);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2'));
    await tester.pump();

    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is SeasonDropPainter),
        findsNothing);
  });

  testWidgets('les épisodes montent en cascade puis sont rendus tels quels',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // À l'arrivée, l'épisode est encore sous un fondu...
    expect(
        find.ancestor(
            of: find.text('Épisode pilote S1'), matching: find.byType(Opacity)),
        findsWidgets);

    await tester.pumpAndSettle();
    // ...et une fois posé, plus aucun calque d'opacité ne reste.
    expect(
        find.ancestor(
            of: find.text('Épisode pilote S1'), matching: find.byType(Opacity)),
        findsNothing);
  });
}
