import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:onyx/models/device_pairing.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/screens/auth/login_screen.dart';
import 'package:onyx/screens/library/movie_detail_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/download_manager.dart';
import 'package:onyx/services/media_details_cache.dart';
import 'package:onyx/services/media_tracks_cache.dart';
import 'package:onyx/widgets/global/continue_watching_card.dart';
import 'package:onyx/widgets/global/poster_card.dart';

import 'onyx_controls_layer_test.dart' show pumpChrome;

class _Api extends ApiClient {
  @override
  Future<bool> getSetupRequired() async => false;

  @override
  Future<DevicePairing> startDevicePairing({required String deviceName}) async =>
      throw Exception('hors ligne');

  @override
  Future<MediaDetails> getMediaDetails(int mediaId) async =>
      MediaDetails.fromJson({'id': mediaId, 'type': 'movie', 'title': 'Film'});

  @override
  Future<MediaTracks> getMediaTracks(int mediaId) async =>
      MediaTracks.fromJson({});

  @override
  Future<Map<String, dynamic>> getProgress(int mediaId) async =>
      {'current_position_seconds': 600, 'is_finished': false};
}

class _Auth extends AuthProvider {
  _Auth(super.api);

  @override
  User? get currentUser =>
      User(id: 1, username: 'mathis', permissions: Permissions.all);

  @override
  Permissions get permissions => Permissions.all;
}

/// Un lecteur d'écran (TalkBack, VoiceOver) ne lit pas une icône : il lit le
/// nom qu'on lui a donné, ou « bouton » tout court. Ces tests montent les
/// écrans que tout le monde traverse et demandent à Flutter si chaque cible
/// cliquable a un nom. Voir ADR-0054.
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

  void phone(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  Future<void> expectEveryTargetNamed(WidgetTester tester) =>
      expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

  testWidgets('chaque commande du lecteur a un nom', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpChrome(
      tester,
      width: 1280,
      onSkipNext: () {},
      onSkipPrevious: () {},
      onOpenEpisodes: () {},
      onSkipIntro: () {},
      onLockScreen: () {},
      brightness: 0.5,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await expectEveryTargetNamed(tester);
    handle.dispose();
  });

  testWidgets('chaque commande du lecteur a un nom, sur un téléphone',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpChrome(
      tester,
      width: 800,
      height: 380,
      showVolume: false,
      onSkipNext: () {},
      onOpenEpisodes: () {},
      onLockScreen: () {},
      brightness: 0.5,
    );
    await tester.pump(const Duration(milliseconds: 400));

    await expectEveryTargetNamed(tester);
    handle.dispose();
  });

  testWidgets('une affiche de la médiathèque porte le titre du média',
      (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 140,
            child: PosterCard(
              posterUrl: null,
              title: 'Dune',
              subtitle: '2021',
              onTap: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    await expectEveryTargetNamed(tester);
    expect(find.bySemanticsLabel(RegExp('Dune')), findsWidgets);
    handle.dispose();
  });

  testWidgets('la carte « À reprendre » nomme ses deux gestes', (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    final item = HomeMediaItem.fromJson({
      'id': 42,
      'type': 'movie',
      'title': 'Le film',
      'duration': 6000,
      'current_position_seconds': 600,
      'is_finished': false,
      'created_at': '2026-09-30T10:00:00Z',
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: _Api(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContinueWatchingCard(
              item: item,
              onTap: (_) {},
              onTitleTap: (_) {},
              onMarkAsWatched: (_) async {},
              onRemoveFromRow: (_) async {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    await expectEveryTargetNamed(tester);
    handle.dispose();
  });

  testWidgets('l’écran de connexion nomme chaque bouton', (tester) async {
    final handle = tester.ensureSemantics();
    final api = _Api();
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider(create: (_) => AuthProvider(api)),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    await expectEveryTargetNamed(tester);
    handle.dispose();
  });

  for (final (name, size) in [
    ('sur un téléphone', const Size(390, 844)),
    ('sur un écran large', const Size(1400, 900)),
  ]) {
    testWidgets('la fiche d’un film nomme chaque action, $name',
        (tester) async {
      final handle = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final api = _Api();
      final auth = _Auth(api);
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

      await expectEveryTargetNamed(tester);
      handle.dispose();
    });
  }
}
