import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/hooks/use_episode_navigation.dart';
import 'package:onyx/screens/player/playback/skip_segments.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_preferences_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Les chapitres d'un épisode qui s'ouvre sur un récap puis une intro.
class _ChaptersServer extends ApiClient {
  @override
  Future<List<VideoChapter>> getEpisodeChapters(int episodeId) async => [
        VideoChapter(id: 1, startTime: 0, endTime: 164, title: 'Recap'),
        VideoChapter(id: 2, startTime: 164, endTime: 252, title: 'Intro'),
        VideoChapter(id: 3, startTime: 252, endTime: 2789, title: 'Chapter 1'),
        VideoChapter(id: 4, startTime: 2789, endTime: 3000, title: 'Credits'),
      ];
}

/// Un récap suivi d'une intro : deux propositions l'une après l'autre,
/// « Passer le récap » puis « Passer l'intro », chacune avec son réglage de
/// saut automatique.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const duration = 3000;

  Future<EpisodeNavigationController> buildController({
    EpisodeTimestamps? timestamps,
    void Function()? onAutoSkip,
  }) async {
    final nav = EpisodeNavigationController(
      apiClient: _ChaptersServer(),
      episodeId: 1,
      initialTimestamps: timestamps ??
          EpisodeTimestamps(
            introStart: 0,
            introEnd: 0,
            outroStart: 0,
            outroEnd: 0,
          ),
      onAutoSkipIntro: onAutoSkip,
    );
    await nav.refreshChapters();
    return nav;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlaybackPreferencesStorage.setAutoSkipIntro(false);
    await PlaybackPreferencesStorage.setAutoSkipRecap(false);
  });

  test('un chapitre « Recap » n\'est pas une intro', () {
    expect(ChapterTitles.isRecap('Recap'), isTrue);
    expect(ChapterTitles.isIntro('Recap'), isFalse);
    expect(ChapterTitles.isIntro('Previously On'), isFalse);
    expect(ChapterTitles.isIntro('Intro'), isTrue);
  });

  testWidgets('le récap se passe, puis l\'intro', (tester) async {
    final nav = await buildController();
    addTearDown(nav.dispose);

    nav.checkPosition(10, mediaDurationSeconds: duration);
    expect(nav.showSkipIntro, isTrue);
    expect(nav.skipSegment, SkipSegment.recap);
    expect(nav.introSkipTarget, 164);

    nav.skipIntro();
    nav.checkPosition(164, mediaDurationSeconds: duration);
    expect(nav.showSkipIntro, isTrue);
    expect(nav.skipSegment, SkipSegment.intro);
    expect(nav.introSkipTarget, 252);
  });

  testWidgets('le récap se saute seul quand son réglage est allumé',
      (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipRecap(true);
    var skipped = 0;
    final nav = await buildController(onAutoSkip: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(10, mediaDurationSeconds: duration);
    expect(nav.introAutoSkipActive, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(skipped, 1);
    expect(nav.introSkipTarget, 164);

    // Le saut n'a pas encore atterri : le récap ne se repropose pas.
    nav.checkPosition(15, mediaDurationSeconds: duration);
    expect(nav.showSkipIntro, isFalse);

    // Arrivé dans l'intro : son propre réglage, éteint, décide.
    nav.checkPosition(164, mediaDurationSeconds: duration);
    expect(nav.skipSegment, SkipSegment.intro);
    expect(nav.introAutoSkipActive, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(skipped, 1);
  });

  testWidgets('le réglage de l\'intro ne saute pas le récap', (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    var skipped = 0;
    final nav = await buildController(onAutoSkip: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(10, mediaDurationSeconds: duration);
    expect(nav.skipSegment, SkipSegment.recap);
    expect(nav.introAutoSkipActive, isFalse);

    // Le récap regardé jusqu'au bout : l'intro arrive avec son compte à rebours.
    nav.checkPosition(165, mediaDurationSeconds: duration);
    expect(nav.skipSegment, SkipSegment.intro);
    expect(nav.introAutoSkipActive, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(skipped, 1);
    expect(nav.introSkipTarget, 252);
  });

  testWidgets('une intro en base qui ne couvre que le récap laisse les '
      'chapitres donner l\'intro', (tester) async {
    final nav = await buildController(
      timestamps: EpisodeTimestamps(
        introStart: 0,
        introEnd: 164,
        outroStart: 0,
        outroEnd: 0,
      ),
    );
    addTearDown(nav.dispose);

    nav.checkPosition(10, mediaDurationSeconds: duration);
    expect(nav.skipSegment, SkipSegment.recap);

    nav.skipIntro();
    nav.checkPosition(170, mediaDurationSeconds: duration);
    expect(nav.showSkipIntro, isTrue);
    expect(nav.skipSegment, SkipSegment.intro);
    expect(nav.introSkipTarget, 252);
  });
}
