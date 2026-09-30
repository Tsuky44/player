import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:onyx/providers/auth_provider.dart';
import 'package:onyx/providers/home_provider.dart';
import 'package:onyx/providers/library_provider.dart';
import 'package:onyx/providers/search_provider.dart';
import 'package:onyx/screens/home/home_screen.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/playback/playback_session.dart';
import 'package:onyx/screens/player/player_shortcuts.dart';
import 'package:onyx/screens/player/widgets/player_chrome_fade.dart';
import 'package:onyx/theme/app_motion.dart';
import 'package:onyx/utils/hero_slides.dart';
import 'package:onyx/utils/search_match.dart';
import 'package:onyx/widgets/global/detail_metadata.dart';
import 'package:onyx/widgets/global/pressable.dart';

class _Session implements PlaybackSession {
  @override
  double volume = 80;

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  homeDiscoveryTests();

  group('titleSortKey', () {
    test('range une initiale accentuée avec sa lettre, pas après Z', () {
      final titles = ['Zodiac', 'Éternels', 'amour', 'Batman'];
      titles.sort((a, b) => titleSortKey(a).compareTo(titleSortKey(b)));
      expect(titles, ['amour', 'Batman', 'Éternels', 'Zodiac']);
    });

    test('ignore l’article en tête, comme une vidéothèque', () {
      final titles = ['Le Parrain', 'The Batman', 'Alien', 'L’Odyssée'];
      titles.sort((a, b) => titleSortKey(a).compareTo(titleSortKey(b)));
      expect(titles, ['Alien', 'The Batman', 'L’Odyssée', 'Le Parrain']);
    });

    test('un titre fait d’un seul article reste rangé à son nom', () {
      expect(titleSortKey('Les'), 'les');
    });
  });

  group('techBadgesFor', () {
    test('définition, dynamique, son immersif puis canaux', () {
      final tracks = MediaTracks.fromJson({
        'video': {
          'codec_name': 'hevc',
          'width': 3840,
          'height': 2160,
          'hdr_format': 'dolbyvision',
        },
        'audio': [
          {'codec_name': 'eac3', 'channels': 6, 'language': 'fre'},
          {
            'codec_name': 'truehd',
            'channels': 8,
            'spatial_format': 'atmos',
            'language': 'eng'
          },
        ],
      });
      final badges = techBadgesFor(tracks);
      expect(badges.first, '4K');
      expect(badges, contains('Dolby Atmos'));
      expect(badges.last, '7.1');
      expect(badges, isNot(contains('HEVC')),
          reason: 'le codec reste dans les informations techniques');
    });

    test('rien quand les pistes ne sont pas encore là', () {
      expect(techBadgesFor(null), isEmpty);
    });
  });

  test('le nom d’une piste audio ne répète pas ce que dit son titre', () {
    final track = MediaAudioTrack.fromJson({
      'codec_name': 'eac3',
      'channels': 6,
      'language': 'fre',
      'title': 'Français 5.1',
    });
    expect(track.displayName, 'Français (5.1 Dolby Digital+)');
  });

  test('le bandeau n’écrit pas l’année deux fois', () {
    final home = HomeResponse.fromJson({
      'continue_watching': [
        {
          'id': 1,
          'type': 'movie',
          'title': 'Dune',
          'duration': 7200,
          'release_date': '2024-02-28',
          'current_position_seconds': 60,
          'updated_at': DateTime.now().toIso8601String(),
        },
      ],
    });
    final slide = buildHeroSlides(home, serverBaseUrl: '').single;
    expect(slide.subtitle ?? '', isNot(contains('2024')),
        reason: 'le bandeau pose l’année lui-même');
    expect(slide.playLabel, 'Reprendre');
  });

  testWidgets('une carte rétrécit dès que le doigt se pose', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: Pressable(
          onTap: () => taps++,
          builder: (context, pressed) => PressScale(
            pressed: pressed,
            child: const SizedBox(width: 100, height: 150),
          ),
        ),
      ),
    ));

    double scale() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scale(), 1.0);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(SizedBox)));
    await tester.pump();
    expect(scale(), AppMotion.pressScale,
        reason: 'le retour arrive au pointer-down, pas au relâchement');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), 1.0);
    expect(taps, 1);
  });

  testWidgets('un chrome masqué ne prend ni le doigt ni le focus',
      (tester) async {
    Widget chrome(bool visible) => MaterialApp(
          home: PlayerChromeFade(
            visible: visible,
            child: TextButton(onPressed: () {}, child: const Text('Lecture')),
          ),
        );

    await tester.pumpWidget(chrome(false));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IgnorePointer>(find
              .ancestor(
                  of: find.byType(AnimatedOpacity),
                  matching: find.byType(IgnorePointer))
              .first)
          .ignoring,
      isTrue,
    );
    expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0);

    await tester.pumpWidget(chrome(true));
    await tester.pump(AppMotion.standard ~/ 2);
    // Toujours monté pendant le fondu : il apparaît, il ne surgit pas.
    expect(find.text('Lecture'), findsOneWidget);
    expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1);
  });

  group('raccourcis du lecteur', () {
    test('les lettres des lecteurs courants', () {
      expect(matchPlayerShortcut(_down(LogicalKeyboardKey.keyF))?.shortcut,
          PlayerShortcut.toggleFullscreen);
      expect(matchPlayerShortcut(_down(LogicalKeyboardKey.keyM))?.shortcut,
          PlayerShortcut.toggleMute);
      expect(matchPlayerShortcut(_down(LogicalKeyboardKey.keyN))?.shortcut,
          PlayerShortcut.nextEpisode);
    });

    test('un chiffre va à sa dizaine de pour cent', () {
      final match = matchPlayerShortcut(_down(LogicalKeyboardKey.digit5));
      expect(match?.shortcut, PlayerShortcut.seekToFraction);
      expect(match?.fraction, 0.5);
    });

    test('« ? » se lit au caractère, quelle que soit la disposition', () {
      final match = matchPlayerShortcut(
          _down(LogicalKeyboardKey.comma, character: '?'));
      expect(match?.shortcut, PlayerShortcut.showHelp);
    });

    test('une touche maintenue ne redéclenche rien', () {
      final repeat = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyF,
        logicalKey: LogicalKeyboardKey.keyF,
        timeStamp: Duration.zero,
      );
      expect(matchPlayerShortcut(repeat), isNull);
    });

    test('M coupe le son, puis le rend au volume d’avant', () {
      final session = _Session();
      togglePlayerMute(session);
      expect(session.volume, 0);
      togglePlayerMute(session);
      expect(session.volume, 80);
    });
  });
}

class _HomeApi extends ApiClient {
  static Map<String, dynamic> _media(int id, String type, String title) => {
        'id': id,
        'type': type,
        'title': title,
        'duration': 6000,
        'created_at': '2026-09-01T10:00:00Z',
      };

  @override
  Future<HomeResponse> getHome() async => HomeResponse.fromJson({
        'recent_movies': [_media(1, 'movie', 'Récent')],
        'discovery_movies': [_media(2, 'movie', 'Film oublié')],
        'discovery_shows': [_media(3, 'show', 'Série oubliée')],
      });

  @override
  Future<List<HomeMediaItem>> getMovies() async => [];

  @override
  Future<List<Media>> getShows() async => [];

  @override
  Future<IndexerStatus> getIndexerStatus() async => IndexerStatus.fromJson({});
}

void homeDiscoveryTests() {
  testWidgets('l’accueil montre la sélection « découverte » du serveur',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _HomeApi();
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider(create: (_) => AuthProvider(api)),
        ChangeNotifierProvider(create: (_) => HomeProvider(api)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(api)),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
      ],
      child: const MaterialApp(home: HomeScreen(embedded: true)),
    ));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('À découvrir'), findsOneWidget);
    expect(find.text('Film oublié'), findsWidgets);
    expect(find.text('Série oubliée'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
  });
}
