import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/library/movie_detail_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/media_details_cache.dart';
import 'package:onyx/services/media_tracks_cache.dart';
import 'package:onyx/utils/format.dart';
import 'package:onyx/widgets/global/detail_actions.dart';

class _Api extends ApiClient {
  _Api({required this.position});

  final int position;

  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async =>
      MediaDetails.fromJson({'id': mediaId, 'type': 'movie', 'title': 'Film'});

  @override
  Future<MediaTracks> getMediaTracks(int mediaId) async =>
      MediaTracks.fromJson({});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async =>
      {'current_position_seconds': position, 'is_finished': false};
}

class _FakeAuth extends AuthProvider {
  _FakeAuth(super.api);

  @override
  User? get currentUser =>
      User(id: 1, username: 'mathis', permissions: Permissions.all);

  @override
  Permissions get permissions => Permissions.all;
}

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

  Future<void> pumpMovie(
    WidgetTester tester, {
    required Size size,
    required int position,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api(position: position);
    final auth = _FakeAuth(api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<DownloadManager>.value(
            value: DownloadManager.instance),
      ],
      child: MaterialApp(
        home: MovieDetailScreen(
          movie: Media(
            id: 1,
            type: MediaType.movie,
            title: 'Film',
            duration: 7200,
            createdAt: DateTime(2026),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('fiche film', () {
    testWidgets('les actions tiennent sur un téléphone de 360 px',
        (tester) async {
      await pumpMovie(tester, size: const Size(360, 800), position: 2700);

      expect(tester.takeException(), isNull,
          reason: 'la rangée d’actions ne doit pas déborder');
      expect(find.text('Reprendre'), findsOneWidget);
      expect(find.byTooltip('Corriger la fiche'), findsOneWidget);
    });

    testWidgets('« Reprendre » dit combien il reste, pas un pourcentage',
        (tester) async {
      await pumpMovie(tester, size: const Size(1200, 1000), position: 2700);

      expect(find.text('Reprendre'), findsOneWidget);
      expect(find.text('1h 15min restantes'), findsOneWidget);
      expect(find.textContaining('% visionné'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('un film jamais commencé propose « Lecture »', (tester) async {
      await pumpMovie(tester, size: const Size(360, 800), position: 0);

      expect(find.text('Lecture'), findsOneWidget);
      expect(find.textContaining('restantes'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // Entre 600 et 900 px l'affiche occupe la gauche de l'en-tête : il reste
    // à peine 330 px aux actions.
    testWidgets('les actions tiennent sur une tablette de 700 px',
        (tester) async {
      await pumpMovie(tester, size: const Size(700, 1000), position: 2700);

      expect(tester.takeException(), isNull);
      expect(find.text('Marquer vu'), findsOneWidget);
    });
  });

  group('detailPlayLabel', () {
    Media episode({int? season, int? number}) => Media(
          id: 9,
          type: MediaType.episode,
          title: 'Épisode',
          duration: 2400,
          seasonNumber: season,
          episodeNumber: number,
          createdAt: DateTime(2026),
        );

    test('un film : deux verbes, en casse de phrase', () {
      expect(detailPlayLabel(resuming: false), 'Lecture');
      expect(detailPlayLabel(resuming: true), 'Reprendre');
    });

    test('une série nomme l’épisode que le bouton lance', () {
      expect(
        detailPlayLabel(resuming: true, episode: episode(season: 2, number: 4)),
        'Reprendre S2 E4',
      );
      expect(
        detailPlayLabel(
            resuming: false, episode: episode(season: 1, number: 1)),
        'Lecture S1 E1',
      );
    });

    test('la saison affichée par la fiche l’emporte sur celle de l’épisode', () {
      expect(
        detailPlayLabel(
          resuming: false,
          episode: episode(season: 1, number: 3),
          seasonOverride: 5,
        ),
        'Lecture S5 E3',
      );
    });

    test('sans numéro d’épisode, le verbe seul', () {
      expect(detailPlayLabel(resuming: true, episode: episode()), 'Reprendre');
    });
  });

  test('formatRemaining ne dit rien quand il ne reste rien', () {
    expect(formatRemaining(4500), '1h 15min restantes');
    expect(formatRemaining(0), isNull);
    expect(formatRemaining(-30), isNull);
  });
}
