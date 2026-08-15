import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/emby/emby_chrome_theme.dart';
import 'package:onyx/screens/player/widgets/emby/emby_controls_layer.dart';

/// Mounts the chrome at a given viewport width.
Future<void> pumpChrome(
  WidgetTester tester, {
  required double width,
  VoidCallback? onSkipNext,
  VoidCallback? onSkipPrevious,
  VoidCallback? onOpenEpisodes,
  VoidCallback? onSkipIntro,
  double volume = 70,
  bool isPlaying = true,
  bool visible = true,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: EmbyControlsLayer(
          visible: visible,
          isPlaying: isPlaying,
          position: const Duration(minutes: 42),
          duration: const Duration(hours: 2),
          buffered: 0.5,
          title: 'Avatar : La Voie de l’eau',
          overline: '2022',
          volume: volume,
          onPlayPause: () {},
          onRewind: () {},
          onForward: () {},
          onSeekFraction: (_) {},
          onVolumeChanged: (_) {},
          onBack: () {},
          onToggleSubtitles: () {},
          onOpenAudio: () {},
          onCycleSpeed: () {},
          onOpenSettings: () {},
          onToggleFullscreen: () {},
          onSkipNext: onSkipNext,
          onSkipPrevious: onSkipPrevious,
          onOpenEpisodes: onOpenEpisodes,
          onSkipIntro: onSkipIntro,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the chrome carries the agreed control set', () {
    testWidgets('every permanent control is present at desktop width',
        (tester) async {
      await pumpChrome(tester, width: 1280);

      for (final icon in [
        Icons.arrow_back_ios_new_rounded,
        Icons.volume_up_rounded,
        Icons.closed_caption_rounded,
        Icons.graphic_eq_rounded,
        Icons.speed_rounded,
        Icons.settings_rounded,
        Icons.fullscreen_rounded,
        Icons.replay_10_rounded,
        Icons.pause_rounded,
        Icons.forward_10_rounded,
      ]) {
        expect(find.byIcon(icon), findsOneWidget, reason: '$icon missing');
      }
    });

    testWidgets('the removed Emby links are nowhere in the chrome',
        (tester) async {
      await pumpChrome(tester, width: 1280);

      expect(find.text('Info'), findsNothing);
      expect(find.text('Chapitres'), findsNothing);
      expect(find.text('Distribution et équipe'), findsNothing);
    });

    testWidgets('no cast or picture-in-picture control', (tester) async {
      await pumpChrome(tester, width: 1280);

      expect(find.byIcon(Icons.cast), findsNothing);
      expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsNothing);
    });

    testWidgets('shows the title block, both lines', (tester) async {
      await pumpChrome(tester, width: 1280);

      expect(find.text('2022'), findsOneWidget);
      // Once in the title block; the top bar falls back to the same text when
      // there is no logo.
      expect(find.text('Avatar : La Voie de l’eau'), findsWidgets);
    });

    testWidgets('times read as elapsed on the left, remaining + end on the right',
        (tester) async {
      await pumpChrome(tester, width: 1280);

      expect(find.text('42:00'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data?.startsWith('-01:18:00  /  ') ?? false),
        ),
        findsOneWidget,
      );
    });
  });

  group('conditional controls only appear when they can act', () {
    testWidgets('no next-episode button on a movie', (tester) async {
      await pumpChrome(tester, width: 1280);
      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
    });

    testWidgets('next-episode button on a series', (tester) async {
      await pumpChrome(tester, width: 1280, onSkipNext: () {});
      expect(find.byIcon(Icons.skip_next_rounded), findsOneWidget);
    });

    testWidgets('no previous-episode button on a movie', (tester) async {
      await pumpChrome(tester, width: 1280);
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);
    });

    testWidgets('previous-episode button when there is one before',
        (tester) async {
      var back = 0;
      await pumpChrome(tester, width: 1280, onSkipPrevious: () => back++);

      expect(find.byIcon(Icons.skip_previous_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.skip_previous_rounded));
      expect(back, 1);
    });

    testWidgets('no episode-list button on a movie', (tester) async {
      await pumpChrome(tester, width: 1280);
      expect(find.byIcon(Icons.playlist_play_rounded), findsNothing);
    });

    testWidgets('episode-list button on a series, and it fires',
        (tester) async {
      var opened = 0;
      await pumpChrome(tester, width: 1280, onOpenEpisodes: () => opened++);

      expect(find.byIcon(Icons.playlist_play_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.playlist_play_rounded));
      expect(opened, 1);
    });

    testWidgets('no skip-intro pill outside an intro chapter', (tester) async {
      await pumpChrome(tester, width: 1280);
      expect(find.text('Passer l’intro'), findsNothing);
    });

    testWidgets('skip-intro pill during an intro chapter', (tester) async {
      await pumpChrome(tester, width: 1280, onSkipIntro: () {});
      expect(find.text('Passer l’intro'), findsOneWidget);
    });

    testWidgets('the skip-intro pill outlives the hidden chrome',
        (tester) async {
      // A user who is not moving the mouse must still be offered the skip:
      // the intro ends whether or not the chrome is up.
      var skipped = 0;
      await pumpChrome(
        tester,
        width: 1280,
        visible: false,
        onSkipIntro: () => skipped++,
      );
      await tester.pumpAndSettle();

      expect(find.text('Passer l’intro'), findsOneWidget);
      await tester.tap(find.text('Passer l’intro'));
      expect(skipped, 1);
    });
  });

  group('the mute button reflects and toggles the level', () {
    testWidgets('shows the muted icon at zero volume', (tester) async {
      await pumpChrome(tester, width: 1280, volume: 0);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    });

    testWidgets('shows the low icon below half', (tester) async {
      await pumpChrome(tester, width: 1280, volume: 20);
      expect(find.byIcon(Icons.volume_down_rounded), findsOneWidget);
    });
  });

  group('both arrangements stay usable', () {
    testWidgets('nothing overflows at phone width', (tester) async {
      await pumpChrome(
          tester,
          width: 375,
          onSkipNext: () {},
          onSkipPrevious: () {},
          onOpenEpisodes: () {},
          onSkipIntro: () {});
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing overflows at desktop width', (tester) async {
      await pumpChrome(
          tester,
          width: 1280,
          onSkipNext: () {},
          onSkipPrevious: () {},
          onOpenEpisodes: () {},
          onSkipIntro: () {});
      expect(tester.takeException(), isNull);
    });

    testWidgets('the volume slider gives way to the mute button when narrow',
        (tester) async {
      await pumpChrome(tester, width: 375);
      expect(find.byType(Slider), findsNothing);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    });

    testWidgets('the volume slider is permanent when there is room',
        (tester) async {
      await pumpChrome(tester, width: 1280);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('compact keeps touch targets at 44px', (tester) async {
      // The whole reason for a second arrangement: a scaled-down single
      // layout would put these well under the usable size.
      const compact = EmbyChromeMetrics.compact();
      expect(compact.hitSize, greaterThanOrEqualTo(44));
    });

    testWidgets('the utility cluster survives both arrangements',
        (tester) async {
      for (final width in [375.0, 1280.0]) {
        await pumpChrome(tester, width: width);
        expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget,
            reason: 'fullscreen lost at $width');
        expect(find.byIcon(Icons.settings_rounded), findsOneWidget,
            reason: 'settings lost at $width');
      }
    });
  });

  testWidgets('hidden chrome stops taking taps', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 700);
    addTearDown(tester.view.reset);

    var backTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbyControlsLayer(
            visible: false,
            isPlaying: true,
            position: Duration.zero,
            duration: const Duration(hours: 2),
            buffered: 0,
            volume: 70,
            onPlayPause: () {},
            onRewind: () {},
            onForward: () {},
            onSeekFraction: (_) {},
            onVolumeChanged: (_) {},
            onBack: () => backTaps++,
            onToggleSubtitles: () {},
            onOpenAudio: () {},
            onCycleSpeed: () {},
            onOpenSettings: () {},
            onToggleFullscreen: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded),
        warnIfMissed: false);
    expect(backTaps, 0);
  });
}
