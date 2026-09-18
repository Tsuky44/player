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
