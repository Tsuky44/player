import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/media_request.dart';
import 'package:onyx/models/my_request.dart';
import 'package:onyx/models/request_release.dart';
import 'package:onyx/providers/media_requests_provider.dart';
import 'package:onyx/screens/requests/widgets/request_release_sheet.dart';
import 'package:onyx/screens/requests/widgets/request_season_panel.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/theme/app_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// La recherche interactive des demandes (ADR-0098) : choisir soi-même la
/// release d'une saison ou d'un épisode, quand le compagnon l'accorde.

RequestRelease _release(
  String title, {
  int size = 1000000000,
  int? seeders = 5,
  double age = 3,
  String id = '',
  String indexer = 'Indexeur',
  String? downloadUrl = 'https://indexer.example/dl',
  bool? accepted,
  List<String> rejections = const [],
}) =>
    RequestRelease(
      id: id.isEmpty ? title : id,
      title: title,
      size: size,
      indexer: indexer,
      indexerId: 4,
      ageDays: age,
      protocol: 'torrent',
      seeders: seeders,
      downloadUrl: downloadUrl,
      accepted: accepted,
      rejections: rejections,
    );

/// Une release telle que sorraa la rend : un jeton, aucune adresse, un verdict.
RequestRelease _judged(
  String title, {
  required bool accepted,
  List<String> rejections = const [],
  int? seeders = 5,
}) =>
    _release(
      title,
      id: 'tok-$title',
      seeders: seeders,
      downloadUrl: null,
      accepted: accepted,
      rejections: rejections,
    );

class _Api extends ApiClient {
  _Api({
    this.releases = const [],
    this.canSearch = true,
    this.failLoad = false,
    this.failGrab = false,
  });

  List<RequestRelease> releases;
  final bool canSearch;
  bool failLoad;
  final bool failGrab;
  final targets = <RequestReleaseTarget>[];
  final grabbed = <String>[];

  @override
  Future<RequestAccess> getRequestAccess() async => RequestAccess(
        service: 'mediahub',
        linked: true,
        canRequest: true,
        canReadAll: false,
        canModerate: false,
        canDelete: false,
        canInteractiveSearch: canSearch,
      );

  @override
  Future<List<RequestEpisode>> getRequestSeasonEpisodes(
    int tmdbId,
    int seasonNumber,
  ) async =>
      [
        const RequestEpisode(
          id: 1,
          number: 3,
          name: 'Le troisième',
          overview: '',
          stillPath: null,
          airDate: null,
          runtime: 0,
          rating: 0,
        ),
      ];

  @override
  Future<List<RequestRelease>> getRequestReleases(
    RequestReleaseTarget target,
  ) async {
    targets.add(target);
    if (failLoad) throw StateError('MediaHub ne répond pas');
    return releases;
  }

  @override
  Future<void> grabRequestRelease(
    RequestReleaseTarget target,
    RequestRelease release,
  ) async {
    if (failGrab) throw StateError('refusée');
    grabbed.add(release.id);
  }
}

Future<void> _pumpSheet(WidgetTester tester, _Api api) async {
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => MediaRequestsProvider(api),
    child: const MaterialApp(
      home: Scaffold(
        body: RequestReleaseSheet(
          target: RequestReleaseTarget(tmdbId: 1399, season: 2, episode: 3),
          heading: 'Saison 2 · Épisode 3',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('RequestRelease', () {
    test('lit une release de MediaHub, avec ses champs absents', () {
      final release = RequestRelease.fromJson({
        'guid': 'g',
        'title': 'Show.S02E03.MULTi.1080p.WEB.H264-GRP',
        'size': 2254857830,
        'indexer': 'Indexeur',
        'indexerId': 4,
        'age': 2.5,
        'protocol': 'usenet',
        'seeders': null,
        'downloadUrl': 'https://indexer.example/download/4821',
        'magnetUrl': null,
      });
      expect(release.size, 2254857830);
      expect(release.seeders, isNull);
      expect(release.magnetUrl, isNull);
      expect(release.isDownloadable, isTrue);
      expect(RequestRelease.fromJson({'guid': 'g'}).isDownloadable, isFalse);
    });

    test('annonce définition, source et langue d’après le nom', () {
      expect(_release('Show.S02E03.MULTi.1080p.WEB.H264-GRP').tags,
          ['1080p', 'WEB', 'MULTI']);
      expect(_release('Show S02 2160p BluRay REMUX TRUEFRENCH').tags,
          ['4K', 'Remux', 'VFF']);
      expect(_release('show.s02e03.720p.hdtv.vostfr').tags,
          ['720p', 'HDTV', 'VOSTFR']);
      expect(_release('Show.S02E03-GRP').tags, isEmpty);
    });

    test('filtre sur tous les mots, dans le nom ou chez l’indexeur', () {
      final releases = [
        _release('Show.S02E03.MULTi.1080p.WEB-GRP'),
        _release('Show.S02E03.MULTi.720p.WEB-GRP'),
        _release('Show.S02E03.VOSTFR.1080p.WEB-GRP', indexer: 'Rare'),
      ];
      List<String> names(String query) => [
            for (final r in RequestRelease.listing(releases, query: query))
              r.title,
          ];
      expect(names('multi 1080p'), ['Show.S02E03.MULTi.1080p.WEB-GRP']);
      expect(names('rare'), ['Show.S02E03.VOSTFR.1080p.WEB-GRP']);
      expect(names('   '), hasLength(3));
      expect(names('introuvable'), isEmpty);
    });

    test('range par seeders, taille ou date, et départage par le nom', () {
      final releases = [
        _release('b', seeders: 5, size: 3, age: 9),
        _release('a', seeders: 5, size: 1, age: 1),
        _release('c', seeders: null, size: 2, age: 5),
        _release('d', seeders: 40, size: 2, age: 5),
      ];
      List<String> order(ReleaseSort sort) => [
            for (final r in RequestRelease.listing(releases, sort: sort))
              r.title,
          ];
      // Sans seeders (Usenet) passe après ceux qui en ont, même zéro.
      expect(order(ReleaseSort.seeders), ['d', 'a', 'b', 'c']);
      expect(order(ReleaseSort.size), ['b', 'c', 'd', 'a']);
      expect(order(ReleaseSort.newest), ['a', 'c', 'd', 'b']);
    });

    test('envoie la cible et la release en entier à MediaHub', () {
      const season = RequestReleaseTarget(tmdbId: 1399, season: 2);
      expect(season.toQuery(), {'tmdbId': 1399, 'type': 'tv', 'season': 2});

      const episode = RequestReleaseTarget(tmdbId: 1399, season: 2, episode: 3);
      expect(episode.toQuery()['episode'], 3);
      final body = _release('Show.S02E03', id: 'g').toGrabJson(episode);
      expect(body['mediaType'], 'tv');
      expect(body['season'], 2);
      expect(body['episode'], 3);
      expect((body['release'] as Map)['id'], 'g');
      expect((body['release'] as Map)['downloadUrl'], isNotNull);
      expect((body['release'] as Map).containsKey('magnetUrl'), isFalse);
      expect(_release('x').toGrabJson(season).containsKey('episode'), isFalse);
    });

    test('lit le jeton, le verdict et les refus de sorraa, sans adresse', () {
      final release = RequestRelease.fromJson({
        'id': 'tok-1',
        'guid': 'tok-1',
        'title': 'Show.S02E03.720p.HDTV-GRP',
        'indexer': 'Idx',
        'indexerId': 3,
        'age': 2,
        'protocol': 'torrent',
        'downloadUrl': null,
        'magnetUrl': null,
        'accepted': false,
        'rejections': ['Pas assez de seeders (1 pour 3 demandés)', 7],
      });
      expect(release.id, 'tok-1');
      expect(release.accepted, isFalse);
      expect(release.isRejected, isTrue);
      expect(release.rejections, ['Pas assez de seeders (1 pour 3 demandés)']);
      // sorraa a gardé la release : le jeton suffit, même refusée à la main.
      expect(release.isDownloadable, isTrue);
      // Un compagnon d'avant sorraa n'envoyait que guid.
      expect(
          RequestRelease.fromJson({'guid': 'g', 'downloadUrl': 'https://x'}).id,
          'g');
      // Radarr/Sonarr : sans verdict, ni refus, et il faut une adresse.
      expect(_release('Show-GRP').isRejected, isFalse);
      expect(_release('Show-GRP', downloadUrl: null).isDownloadable, isFalse);
    });

    test('garde l’ordre du compagnon : celui de sorraa, la meilleure en tête',
        () {
      final releases = [
        _judged('b', accepted: true, seeders: 1),
        _judged('a', accepted: true, seeders: 40),
        _judged('c', accepted: false, seeders: 90),
      ];
      List<String> order(ReleaseSort sort) => [
            for (final r in RequestRelease.listing(releases, sort: sort))
              r.title,
          ];
      expect(order(ReleaseSort.recommended), ['b', 'a', 'c']);
      expect(order(ReleaseSort.seeders), ['c', 'a', 'b']);
      // Le filtre ne change pas l'ordre.
      expect(
        [
          for (final r in RequestRelease.listing(releases, query: 'tok'))
            r.title
        ],
        isEmpty,
        reason: 'le filtre porte sur le nom et l’indexeur, pas sur le jeton',
      );
    });

    test('lit le droit de recherche interactive du compte', () {
      expect(
        RequestAccess.fromJson({
          'service': 'mediahub',
          'can': {'interactiveSearch': true},
        }).canInteractiveSearch,
        isTrue,
      );
      // Un serveur d'avant la route ne dit rien : pas de recherche.
      expect(
          RequestAccess.fromJson({'service': 'mediahub'}).canInteractiveSearch,
          isFalse);
      expect(RequestAccess.basic.canInteractiveSearch, isFalse);
    });
  });

  group('RequestReleaseSheet', () {
    testWidgets('liste les releases, le filtre en retire, un toucher l’envoie',
        (tester) async {
      final api = _Api(releases: [
        _release('Show.S02E03.MULTi.1080p.WEB-GRP', seeders: 42),
        _release('Show.S02E03.VOSTFR.720p.HDTV-GRP', seeders: 7),
      ]);
      await _pumpSheet(tester, api);

      expect(api.targets.single.season, 2);
      expect(api.targets.single.episode, 3);
      expect(find.text('Saison 2 · Épisode 3'), findsOneWidget);
      expect(find.text('Show.S02E03.MULTi.1080p.WEB-GRP'), findsOneWidget);
      expect(find.text('Show.S02E03.VOSTFR.720p.HDTV-GRP'), findsOneWidget);
      expect(find.text('▲ 42'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'vostfr');
      await tester.pumpAndSettle();
      expect(find.text('Show.S02E03.MULTi.1080p.WEB-GRP'), findsNothing);

      await tester.tap(find.byTooltip('Télécharger cette release'));
      await tester.pumpAndSettle();
      expect(api.grabbed, ['Show.S02E03.VOSTFR.720p.HDTV-GRP']);
      expect(find.byTooltip('Release envoyée'), findsOneWidget);

      // Une release partie ne repart pas au second toucher.
      await tester.tap(find.text('Show.S02E03.VOSTFR.720p.HDTV-GRP'));
      await tester.pumpAndSettle();
      expect(api.grabbed, hasLength(1));
    });

    testWidgets(
        'avec sorraa : l’ordre du moteur, les refus dits, et une refusée reste prenable',
        (tester) async {
      final api = _Api(releases: [
        _judged('Show.S02E03.MULTi.1080p-GRP', accepted: true, seeders: 3),
        _judged('Show.S02E03.720p.HDTV-GRP',
            accepted: false,
            seeders: 90,
            rejections: ['Pas assez de seeders (1 pour 3 demandés)']),
      ]);
      await _pumpSheet(tester, api);

      // L'ordre de sorraa, pas celui des seeders (la refusée en a le plus).
      expect(
        tester.getTopLeft(find.text('Show.S02E03.MULTi.1080p-GRP')).dy,
        lessThan(tester.getTopLeft(find.text('Show.S02E03.720p.HDTV-GRP')).dy),
      );
      expect(find.text('Recommandées'), findsOneWidget);
      expect(find.text('Pas assez de seeders (1 pour 3 demandés)'),
          findsOneWidget);

      await tester.tap(find.text('Show.S02E03.720p.HDTV-GRP'));
      await tester.pumpAndSettle();
      // Le jeton part, sans adresse : sorraa a gardé la release.
      expect(api.grabbed, ['tok-Show.S02E03.720p.HDTV-GRP']);
    });

    testWidgets(
        'sans sorraa : pas de tri « Recommandées », les seeders d’abord',
        (tester) async {
      final api = _Api(releases: [
        _release('Show.S02E03.A-GRP', seeders: 3),
        _release('Show.S02E03.B-GRP', seeders: 90),
      ]);
      await _pumpSheet(tester, api);

      expect(find.text('Recommandées'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Show.S02E03.B-GRP')).dy,
        lessThan(tester.getTopLeft(find.text('Show.S02E03.A-GRP')).dy),
      );
    });

    testWidgets('une saison sans release le dit', (tester) async {
      await _pumpSheet(tester, _Api());
      expect(find.text('Aucune release trouvée.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('un échec de recherche se réessaie', (tester) async {
      final api = _Api(failLoad: true);
      await _pumpSheet(tester, api);
      expect(find.text('Impossible de charger les releases.'), findsOneWidget);

      api
        ..failLoad = false
        ..releases = [_release('Show.S02E03.1080p-GRP')];
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(find.text('Show.S02E03.1080p-GRP'), findsOneWidget);
    });

    testWidgets('un envoi refusé le dit et laisse la release à renvoyer',
        (tester) async {
      final api =
          _Api(releases: [_release('Show.S02E03.1080p-GRP')], failGrab: true);
      await _pumpSheet(tester, api);

      await tester.tap(find.byTooltip('Télécharger cette release'));
      await tester.pumpAndSettle();

      expect(find.text('Impossible d’envoyer la release.'), findsOneWidget);
      expect(find.byTooltip('Télécharger cette release'), findsOneWidget);
    });

    testWidgets('une release sans lien ne s’envoie pas', (tester) async {
      final api = _Api(
          releases: [_release('Show.S02E03.1080p-GRP', downloadUrl: null)]);
      await _pumpSheet(tester, api);

      await tester.tap(find.text('Show.S02E03.1080p-GRP'));
      await tester.pumpAndSettle();
      expect(api.grabbed, isEmpty);
    });
  });

  group('panneau de saison', () {
    const show = RequestMediaItem(
      id: 1399,
      mediaType: RequestMediaType.tv,
      title: 'Série',
      overview: '',
      posterPath: null,
      backdropPath: null,
      releaseDate: null,
      rating: 0,
      status: RequestMediaStatus.unknown,
    );
    const season = RequestSeason(
      number: 2,
      name: 'Saison 2',
      episodeCount: 8,
      posterPath: null,
      status: RequestMediaStatus.available,
    );

    Future<void> pumpPanel(WidgetTester tester, _Api api) async {
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => MediaRequestsProvider(api),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RequestSeasonPanel(
                tmdbId: 1399,
                showItem: show,
                season: season,
                cache: {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('propose la recherche de la saison et de chaque épisode',
        (tester) async {
      final api = _Api(releases: [_release('Show.S02-GRP')]);
      await pumpPanel(tester, api);

      expect(find.text('Recherche interactive'), findsOneWidget);
      expect(find.byTooltip('Recherche interactive'), findsOneWidget);

      await tester.tap(find.text('Recherche interactive'));
      await tester.pumpAndSettle();
      expect(api.targets.single.season, 2);
      expect(api.targets.single.episode, isNull);
      expect(find.text('Show.S02-GRP'), findsOneWidget);

      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Recherche interactive'));
      await tester.pumpAndSettle();
      expect(api.targets.last.episode, 3);
      expect(find.text('Saison 2 · Épisode 3'), findsOneWidget);
    });

    testWidgets('ne la propose pas sans le droit', (tester) async {
      await pumpPanel(tester, _Api(canSearch: false));

      expect(find.text('Recherche interactive'), findsNothing);
      expect(find.byIcon(AppIcons.search), findsNothing);
    });
  });
}
