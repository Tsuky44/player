import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/navigation/detail_flight.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/providers/library_provider.dart';
import 'package:onyx/providers/watch_lists_provider.dart';
import 'package:onyx/screens/library/movie_detail_screen.dart';
import 'package:onyx/screens/library/widgets/season_tabs.dart';
import 'package:onyx/theme/app_colors.dart';
import 'package:onyx/theme/app_icons.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/media_details_cache.dart';
import 'package:onyx/services/media_tracks_cache.dart';
import 'package:onyx/widgets/global/detail_hero.dart';
import 'package:onyx/widgets/global/detail_info_table.dart';
import 'package:onyx/widgets/global/media_card.dart';
import 'package:onyx/widgets/global/poster_card.dart';
import 'package:onyx/widgets/global/poster_flight.dart';
import 'package:onyx/widgets/global/progress_pill.dart';
import 'package:onyx/widgets/global/watch_badge.dart';

class _Api extends ApiClient {
  _Api({this.backdrop});

  final String? backdrop;

  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async =>
      MediaDetails.fromJson({
        'id': mediaId,
        'type': 'movie',
        'title': 'Film',
        'overview': 'Un résumé.',
        'vote_average': 8.3,
        'director': 'Une réalisatrice',
        if (backdrop != null) 'backdrop_url': backdrop,
      });

  @override
  Future<MediaTracks> getMediaTracks(int mediaId) async =>
      MediaTracks.fromJson({});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async =>
      {'current_position_seconds': 2700, 'is_finished': false};
}

class _Auth extends AuthProvider {
  _Auth(super.api);

  @override
  User? get currentUser =>
      User(id: 1, username: 'mathis', permissions: Permissions.all);

  @override
  Permissions get permissions => Permissions.all;
}

Media _movie() => Media(
      id: 1,
      type: MediaType.movie,
      title: 'Film',
      duration: 7200,
      createdAt: DateTime(2026),
    );

/// Une fiche et une carte de la bibliothèque ont le dessin et les animations de
/// celles de Demander, et gardent ce qu'elles seules savent : où on en est, si
/// le titre est vu. Voir ADR-0099.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    MediaDetailsCache.clear();
    MediaTracksCache.clear();
  });

  Widget providers(ApiClient api, AuthProvider auth, Widget home) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider(create: (_) => WatchListsProvider(api)),
          ChangeNotifierProvider<DownloadManager>.value(
              value: DownloadManager.instance),
        ],
        child: MaterialApp(home: home),
      );

  testWidgets(
      'la fiche d’un film prend l’en-tête commun et garde sa progression',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);
    final api = _Api();
    final auth = _Auth(api);
    addTearDown(auth.dispose);

    await tester.pumpWidget(
        providers(api, auth, MovieDetailScreen(movie: _movie())));
    await tester.pumpAndSettle();

    expect(find.byType(DetailHero), findsOneWidget);
    expect(find.byType(DetailInfoTable), findsOneWidget);
    expect(find.widgetWithText(HeroPill, 'Reprendre'), findsOneWidget);
    expect(find.text('1h 15min restantes'), findsOneWidget);
    expect(find.byTooltip('Marquer vu'), findsOneWidget);
    expect(find.text('Un résumé.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('une affiche de la bibliothèque garde le vu et la progression',
      (tester) async {
    final api = _Api();
    final auth = _Auth(api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(providers(
      api,
      auth,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 150,
            height: 225,
            child: MediaCard(
              media: _movie(),
              watched: true,
              progress: 0.4,
              onTap: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final card = tester.widget<PosterCard>(find.byType(PosterCard));
    expect(card.showMeta, isFalse, reason: 'l’affiche seule, comme Demander');
    expect(card.hoverDetails, isNotNull, reason: 'le cartouche au survol');
    expect(find.byType(WatchBadge), findsOneWidget);
    expect(find.byType(ProgressPill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'sur une série, seule une saison demandée porte le sablier orange',
      (tester) async {
    Media season(int number, {bool available = true, String? status}) =>
        Media.fromJson({
          'id': 10 + number,
          'type': 'season',
          'title': 'Saison $number',
          'season_number': number,
          'duration': 0,
          'is_available': available,
          'request_status': status,
          'created_at': '2026-01-01T00:00:00Z',
        });
    final seasons = [
      season(1),
      season(2, available: false, status: 'pending'),
      season(3, available: false),
    ];
    final picked = <Media>[];
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api(),
      child: MaterialApp(
        home: Scaffold(
          body: SeasonTabs(
            seasons: seasons,
            selected: null,
            onSelected: picked.add,
          ),
        ),
      ),
    ));

    expect(find.byIcon(AppIcons.add), findsNothing);
    expect(find.byIcon(AppIcons.cloudOff), findsNothing);
    final hourglass = tester.widget<Icon>(find.byIcon(AppIcons.pending));
    expect(hourglass.color, AppColors.warning);

    await tester.tap(find.text('3'));
    await tester.pump();
    expect(picked.single.effectiveSeasonNumber, 3,
        reason: 'une saison manquante se déplie comme les autres');
  });

  group('openMediaDetail', () {
    Future<NavigatorState> pumpCard(WidgetTester tester, ApiClient api,
        AuthProvider auth) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider(create: (_) => LibraryProvider(api)),
          ChangeNotifierProvider(create: (_) => WatchListsProvider(api)),
          ChangeNotifierProvider<DownloadManager>.value(
              value: DownloadManager.instance),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 225,
                child: MediaCard(media: _movie()),
              ),
            ),
          ),
        ),
      ));
      return navigator.currentState!;
    }

    testWidgets('toucher une affiche lance l’envol quand le fond est connu',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.reset);
      final api = _Api(backdrop: 'https://image.tmdb.org/t/p/w1280/f.jpg');
      final auth = _Auth(api);
      addTearDown(auth.dispose);
      await MediaDetailsCache.load(api, 1);
      final navigator = await pumpCard(tester, api, auth);

      Route<dynamic>? top;
      navigator.popUntil((route) {
        top = route;
        return true;
      });
      expect(top, isNot(isA<PosterFlightRoute<void>>()));

      await tester.tap(find.byType(MediaCard));
      await tester.pump();
      await tester.pump();

      navigator.popUntil((route) {
        top = route;
        return true;
      });
      expect(top, isA<PosterFlightRoute<void>>());
      await tester.pumpAndSettle();
      expect(find.byType(DetailHero), findsOneWidget);
    });

    testWidgets('« réduire les animations » garde une route ordinaire',
        (tester) async {
      final api = _Api(backdrop: 'https://image.tmdb.org/t/p/w1280/f.jpg');
      final auth = _Auth(api);
      addTearDown(auth.dispose);
      await MediaDetailsCache.load(api, 1);
      final key = GlobalKey();
      await tester.pumpWidget(providers(
        api,
        auth,
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: SizedBox(key: key, width: 150, height: 225)),
        ),
      ));

      final context = key.currentContext!;
      final navigator = Navigator.of(context);
      openMediaDetail(context, _movie());
      await tester.pump();
      await tester.pump();

      Route<dynamic>? top;
      navigator.popUntil((route) {
        top = route;
        return true;
      });
      expect(top, isA<MaterialPageRoute<void>>());
      await tester.pumpAndSettle();
    });
  });
}
