import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/providers/media_requests_provider.dart';
import 'package:onyx/screens/requests/widgets/request_season_list.dart';
import 'package:onyx/services/api_client.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fiche d'une demande : les saisons sont des bulles sur une seule ligne, comme
/// sur OnyxHub. Toucher l'une la gonfle en pilule et ouvre ses épisodes en
/// dessous, une seule à la fois.

class _Api extends ApiClient {
  final List<int> calls = [];

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
    expect(tester.getSize(_bubble('Saison 1, 10 épisodes')), const Size(48, 48));
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

  testWidgets('un nom de saison long est coupé dans la bulle, entier dans l’en-tête',
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
    expect(tester.getSize(_bubble('Saison 1, 10 épisodes')), const Size(48, 48));

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
}
