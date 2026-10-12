import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/screens/player/hooks/use_episode_navigation.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_preferences_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The intro that skips itself: same countdown, same freeze-on-any-input as the
/// next episode, and nothing at all until the preference is turned on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  EpisodeNavigationController buildController({
    required void Function() onAutoSkipIntro,
  }) {
    return EpisodeNavigationController(
      apiClient: ApiClient(),
      episodeId: 1,
      initialTimestamps: EpisodeTimestamps(
        introStart: 10,
        introEnd: 100,
        outroStart: 0,
        outroEnd: 0,
      ),
      onAutoSkipIntro: onAutoSkipIntro,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlaybackPreferencesStorage.setAutoSkipIntro(false);
  });

  testWidgets('skips the intro on its own once the countdown runs out',
      (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    var skipped = 0;
    final nav = buildController(onAutoSkipIntro: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(20, mediaDurationSeconds: 3000);
    expect(nav.showSkipIntro, isTrue);
    expect(nav.introAutoSkipActive, isTrue);

    await tester.pump(const Duration(seconds: 3));
    expect(skipped, 0, reason: 'still counting down');
    expect(nav.introCountdownSeconds, 2);

    await tester.pump(const Duration(seconds: 2));
    expect(skipped, 1);
    expect(nav.showSkipIntro, isFalse);
    expect(nav.introAutoSkipActive, isFalse);
    expect(nav.introSkipTarget, 100);
  });

  testWidgets('a mouse move or a key press calls the skip off', (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    var skipped = 0;
    final nav = buildController(onAutoSkipIntro: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(20, mediaDurationSeconds: 3000);
    await tester.pump(const Duration(seconds: 2));
    nav.onUserActivity();

    expect(nav.introAutoSkipFrozen, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(skipped, 0);
    // The offer itself stays: the button is still there to be pressed.
    expect(nav.showSkipIntro, isTrue);
  });

  testWidgets('does nothing at all while the preference is off',
      (tester) async {
    var skipped = 0;
    final nav = buildController(onAutoSkipIntro: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(20, mediaDurationSeconds: 3000);
    expect(nav.showSkipIntro, isTrue);
    expect(nav.introAutoSkipActive, isFalse);

    await tester.pump(const Duration(seconds: 10));
    expect(skipped, 0);
    expect(nav.showSkipIntro, isTrue);
  });

  testWidgets('the pill fills only while the countdown runs', (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    final nav = buildController(onAutoSkipIntro: () {});
    addTearDown(nav.dispose);

    expect(nav.introAutoSkipCountdown, isNull);
    nav.checkPosition(20, mediaDurationSeconds: 3000);
    expect(
      nav.introAutoSkipCountdown,
      const Duration(seconds: EpisodeNavigationController.autoSkipIntroSeconds),
    );

    nav.onUserActivity();
    expect(nav.introAutoSkipCountdown, isNull);
  });

  testWidgets('a skipped intro is not offered again while the seek lands',
      (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    var skipped = 0;
    final nav = buildController(onAutoSkipIntro: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(20, mediaDurationSeconds: 3000);
    await tester.pump(const Duration(seconds: 5));
    expect(skipped, 1);

    // The seek is slow: the position still reads inside the intro.
    nav.checkPosition(26, mediaDurationSeconds: 3000);
    expect(nav.showSkipIntro, isFalse);
    await tester.pump(const Duration(seconds: 10));
    expect(skipped, 1);

    // Landed, then brought back by hand: it is an intro like any other again.
    nav.checkPosition(100, mediaDurationSeconds: 3000);
    nav.checkPosition(20, mediaDurationSeconds: 3000);
    expect(nav.showSkipIntro, isTrue);
    nav.skipIntro();
  });

  testWidgets('leaving the intro puts the countdown away', (tester) async {
    await PlaybackPreferencesStorage.setAutoSkipIntro(true);
    var skipped = 0;
    final nav = buildController(onAutoSkipIntro: () => skipped++);
    addTearDown(nav.dispose);

    nav.checkPosition(20, mediaDurationSeconds: 3000);
    await tester.pump(const Duration(seconds: 2));
    // Seeked past the intro by hand.
    nav.checkPosition(400, mediaDurationSeconds: 3000);
    expect(nav.showSkipIntro, isFalse);
    expect(nav.introAutoSkipActive, isFalse);

    await tester.pump(const Duration(seconds: 10));
    expect(skipped, 0);
  });
}
