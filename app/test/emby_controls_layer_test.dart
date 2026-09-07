import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/widgets/emby/emby_brightness_slider.dart';
import 'package:onyx/screens/player/widgets/emby/emby_chrome_theme.dart';
import 'package:onyx/screens/player/widgets/emby/emby_controls_layer.dart';

/// Mounts the chrome at a given viewport width.
Future<void> pumpChrome(
  WidgetTester tester, {
  required double width,
  double height = 700,
  VoidCallback? onSkipNext,
  VoidCallback? onSkipPrevious,
  VoidCallback? onOpenEpisodes,
  VoidCallback? onSkipIntro,
  double volume = 70,
  bool showVolume = true,
  double scale = 1,
  List<Rect> cutouts = const [],
  double? brightness,
  ValueChanged<double>? onBrightnessChanged,
  bool isPlaying = true,
  bool visible = true,
  bool isTv = false,
  FocusNode? playPauseFocusNode,
  FocusNode? progressFocusNode,
  VoidCallback? onBack,
  VoidCallback? onRewind,
  VoidCallback? onForward,
  VoidCallback? onPlayPause,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
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
          onPlayPause: onPlayPause ?? () {},
          onRewind: onRewind ?? () {},
          onForward: onForward ?? () {},
          onSeekFraction: (_) {},
          onVolumeChanged: (_) {},
          showVolume: showVolume,
          cutouts: cutouts,
          scale: scale,
          brightness: brightness,
          onBrightnessChanged: onBrightnessChanged ?? (_) {},
          onBack: onBack ?? () {},
          onToggleSubtitles: () {},
          onOpenAudio: () {},
          onCycleSpeed: () {},
          onOpenSettings: () {},
          onToggleFullscreen: () {},
          onSkipNext: onSkipNext,
          onSkipPrevious: onSkipPrevious,
          onOpenEpisodes: onOpenEpisodes,
          onSkipIntro: onSkipIntro,
          isTv: isTv,
          playPauseFocusNode: playPauseFocusNode,
          progressFocusNode: progressFocusNode,
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

  group('the brightness bar', () {
    testWidgets('is left out when the screen backlight is not ours to drive',
        (tester) async {
      // Desktop, television, browser: `brightness` arrives null and the bar
      // must not be there at all rather than sit inert on the edge.
      await pumpChrome(tester, width: 1280);

      expect(find.byType(EmbyBrightnessSlider), findsNothing);
    });

    testWidgets('takes the band between the two bars, on the right edge',
        (tester) async {
      await pumpChrome(tester, width: 420, brightness: 0.5);

      final bar = find.byType(EmbyBrightnessSlider);
      expect(bar, findsOneWidget);

      final rect = tester.getRect(bar);
      expect(rect.right, greaterThan(420 - 60));
      // Below the top bar, which is measured rather than guessed at: the
      // control starts where the bar above it ends.
      final back = tester.getRect(find.byIcon(Icons.arrow_back_ios_new_rounded));
      expect(rect.top, greaterThanOrEqualTo(back.bottom));
    });

    testWidgets('never reaches the buttons it shares an edge with',
        (tester) async {
      // The failure this closes was invisible: where the control overlapped
      // the utilities cluster, those buttons were hit-tested first and took
      // the touches, so the lower part of the bar simply stopped answering
      // while still being drawn.
      await pumpChrome(tester, width: 420, brightness: 0.5);

      final rect = tester.getRect(find.byType(EmbyBrightnessSlider));
      final fullscreen =
          tester.getRect(find.byIcon(Icons.fullscreen_rounded));

      expect(rect.bottom, lessThanOrEqualTo(fullscreen.top));
    });

    testWidgets('dragging up brightens and dragging down dims', (tester) async {
      final values = <double>[];
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        onBrightnessChanged: values.add,
      );

      final bar = find.byType(EmbyBrightnessSlider);
      await tester.drag(bar, const Offset(0, -60));
      await tester.pump();
      expect(values.last, greaterThan(0.5),
          reason: 'up is brighter, the direction the bar itself grows');

      values.clear();
      await tester.drag(bar, const Offset(0, 60));
      await tester.pump();
      expect(values.last, lessThan(0.5));
    });

    testWidgets('still there on a screen too short to be comfortable',
        (tester) async {
      // A 1080p phone at 3x, held sideways: 360 dp of height, of which this
      // chrome's bottom bar takes two thirds. The band left is barely 70 px,
      // and the bar has to live in it — it vanished outright at one point,
      // which is worse than tight.
      await pumpChrome(tester, width: 800, height: 360, brightness: 0.5);

      expect(find.byType(EmbyBrightnessSlider), findsOneWidget);
      final rect = tester.getRect(find.byType(EmbyBrightnessSlider));
      final fullscreen =
          tester.getRect(find.byIcon(Icons.fullscreen_rounded));
      expect(rect.bottom, lessThanOrEqualTo(fullscreen.top));
    });

    testWidgets('holds still under a camera bubble', (tester) async {
      // The jitter this closes: dodging a bubble used to be able to move a row
      // *down*, which changed its height, which moved the rows around it — and
      // in a bar pinned to the bottom of the screen, that moved the row itself.
      // The next frame measured a different position and asked for a different
      // dodge, so the chrome never settled.
      await pumpChrome(
        tester,
        width: 800,
        height: 360,
        brightness: 0.5,
        cutouts: const [Rect.fromLTWH(0, 120, 40, 80)],
      );

      final bar = tester.getRect(find.byType(EmbyBrightnessSlider));
      final fullscreen =
          tester.getRect(find.byIcon(Icons.fullscreen_rounded));

      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(tester.getRect(find.byType(EmbyBrightnessSlider)), bar);
      expect(tester.getRect(find.byIcon(Icons.fullscreen_rounded)), fullscreen);
    });

    testWidgets('a finger that lands beside the bar still drives it',
        (tester) async {
      // The point of the catch area: it is much wider than the track, and
      // invisible, so the finger never has to find the 8 px that are drawn.
      final values = <double>[];
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        onBrightnessChanged: values.add,
      );

      final rect = tester.getRect(find.byType(EmbyBrightnessSlider));
      await tester.dragFrom(
        Offset(rect.left + 8, rect.center.dy),
        const Offset(0, -60),
      );
      await tester.pump();

      expect(values.last, greaterThan(0.5));
    });

    testWidgets('the catch area reaches past both ends of the bar',
        (tester) async {
      // Both ends, because they have to be even. A finger lands lower than it
      // aims — the pad touches the glass, the tip does the aiming — so a catch
      // area generous above the track and stopping at the icon grabs first
      // time at the top and hardly at all at the bottom.
      final values = <double>[];
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        onBrightnessChanged: values.add,
      );
      final rect = tester.getRect(find.byType(EmbyBrightnessSlider));

      await tester.dragFrom(
        Offset(rect.center.dx, rect.bottom - 4),
        const Offset(0, -60),
      );
      await tester.pump();
      expect(values.last, greaterThan(0.5), reason: 'below the icon');

      values.clear();
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + 4),
        const Offset(0, 60),
      );
      await tester.pump();
      expect(values.last, lessThan(0.5), reason: 'above the track');
    });

    testWidgets('a touch that goes nowhere changes nothing', (tester) async {
      // Landing on the column is not an adjustment. Jumping to the touch made
      // every stray contact something to undo — and it is what a catch area
      // this wide could not afford.
      final values = <double>[];
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        onBrightnessChanged: values.add,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(EmbyBrightnessSlider)),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(values, isEmpty);
    });

    testWidgets('a drag past either end stays inside 0..1', (tester) async {
      final values = <double>[];
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        onBrightnessChanged: values.add,
      );

      final bar = find.byType(EmbyBrightnessSlider);
      await tester.drag(bar, const Offset(0, -600));
      await tester.pump();
      await tester.drag(bar, const Offset(0, 600));
      await tester.pump();

      expect(values, isNotEmpty);
      for (final v in values) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    testWidgets('hides with the rest of the chrome', (tester) async {
      await pumpChrome(
        tester,
        width: 420,
        brightness: 0.5,
        visible: false,
      );

      final opacity = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(EmbyBrightnessSlider),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(opacity.opacity, 0);
    });
  });

  group('drawn smaller on an iPhone', () {
    test('scaling trims what is drawn and leaves what is touched', () {
      // The whole point of the split: a chrome that looks 10% smaller and is
      // 10% harder to press is not the same trade.
      const base = EmbyChromeMetrics.wide();
      final small = base.scaledBy(0.9);

      expect(small.titleSize, closeTo(base.titleSize * 0.9, 0.001));
      expect(small.iconSize, closeTo(base.iconSize * 0.9, 0.001));
      expect(small.gutter, closeTo(base.gutter * 0.9, 0.001));
      expect(small.hitSize, base.hitSize);
      expect(small.barThickness, base.barThickness);
      expect(small.isCompact, base.isCompact);
    });

    testWidgets('the icons come out smaller and the targets do not',
        (tester) async {
      Size targetOf(WidgetTester tester) => tester.getSize(
            find
                .ancestor(
                  of: find.byIcon(Icons.fullscreen_rounded),
                  matching: find.byType(GestureDetector),
                )
                .first,
          );

      // The glyph, not its box: the box is the target, and that is the half
      // that must not move.
      double glyphOf(WidgetTester tester) =>
          tester.widget<Icon>(find.byIcon(Icons.fullscreen_rounded)).size!;

      await pumpChrome(tester, width: 1280);
      final glyphAtFullSize = glyphOf(tester);
      final targetAtFullSize = targetOf(tester);

      await pumpChrome(tester, width: 1280, scale: 0.9);

      expect(glyphOf(tester), closeTo(glyphAtFullSize * 0.9, 0.001));
      expect(targetOf(tester), targetAtFullSize);
    });
  });

  group('driven by a remote', () {
    testWidgets('the volume control is left out of the television chrome',
        (tester) async {
      await pumpChrome(tester, width: 1280, isTv: true);

      // Both halves of it: the set owns the volume, and the slider was the one
      // focusable widget in this chrome — the remote landed on it and stayed.
      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('the volume control stays everywhere else', (tester) async {
      await pumpChrome(tester, width: 1280);

      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    });

    testWidgets('a phone is left out of it too', (tester) async {
      // Same reasoning as the television, different hardware: the handset has
      // volume keys under the fingers already holding it, and the top row is
      // short of slots.
      await pumpChrome(tester, width: 420, showVolume: false);

      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('the remote is handed play/pause on the way in',
        (tester) async {
      final playPause = FocusNode();
      addTearDown(playPause.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        playPauseFocusNode: playPause,
      );

      playPause.requestFocus();
      await tester.pump();

      expect(playPause.hasFocus, isTrue);
    });

    testWidgets('every control in the bar can take the focus', (tester) async {
      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        onSkipNext: () {},
        onSkipPrevious: () {},
        onOpenEpisodes: () {},
      );

      // One per button: back, episodes, subtitles, audio, speed, settings,
      // fullscreen, previous, rewind, play/pause, forward, next. A count is
      // what catches a control added later without a way to reach it.
      final focusable = tester
          .widgetList<Focus>(find.byType(Focus))
          .where((f) => f.canRequestFocus)
          .length;
      expect(focusable, greaterThanOrEqualTo(12));
    });

    testWidgets('a hidden chrome holds no focus', (tester) async {
      final playPause = FocusNode();
      addTearDown(playPause.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        visible: false,
        playPauseFocusNode: playPause,
      );

      playPause.requestFocus();
      await tester.pump();

      // Faded out, the bar is still in the tree. If its buttons could still be
      // focused the remote would walk a control bar nobody can see.
      expect(playPause.hasFocus, isFalse);
    });
  });

  group('the D-pad walks the television chrome', () {
    testWidgets('up from the transport row lands on the scrubber, which seeks',
        (tester) async {
      var rewound = 0;
      final playPause = FocusNode();
      addTearDown(playPause.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        playPauseFocusNode: playPause,
        onRewind: () => rewound++,
      );

      playPause.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      // Left on the scrubber seeks instead of moving the focus: that is how we
      // know the focus landed there and not on a button that ignores it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(rewound, 1);
    });

    testWidgets('the scrubber takes the node the player hands it',
        (tester) async {
      var rewound = 0;
      final progress = FocusNode();
      addTearDown(progress.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        progressFocusNode: progress,
        onRewind: () => rewound++,
      );

      // The player puts the remote here the moment the HUD comes up, so it
      // has to be reachable by node and not only by traversal.
      progress.requestFocus();
      await tester.pump();
      expect(progress.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(rewound, 1);
    });

    testWidgets('OK on the scrubber is play/pause', (tester) async {
      var toggled = 0;
      final progress = FocusNode();
      addTearDown(progress.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        progressFocusNode: progress,
        onPlayPause: () => toggled++,
      );

      progress.requestFocus();
      await tester.pump();

      // The bar is where the remote lands, so the most common press of all
      // has to work from it without walking down to the transport row.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(toggled, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(toggled, 2);
    });

    testWidgets('up from the scrubber reaches the back button', (tester) async {
      var backs = 0;
      final playPause = FocusNode();
      addTearDown(playPause.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        playPauseFocusNode: playPause,
        onBack: () => backs++,
      );

      playPause.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // scrubber
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // back button
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(backs, 1);
    });

    testWidgets('the settings button is reachable going right along the row',
        (tester) async {
      final playPause = FocusNode();
      addTearDown(playPause.dispose);

      await pumpChrome(
        tester,
        width: 1280,
        isTv: true,
        playPauseFocusNode: playPause,
      );

      playPause.requestFocus();
      await tester.pump();

      // The utilities live on the transport row in this arrangement, so the
      // remote reaches them by walking right — never by guessing a jump
      // upwards into a cluster that is not in its band.
      var reached = false;
      for (var press = 0; press < 12 && !reached; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        final context = primaryFocus?.context;
        if (context == null) continue;
        reached = find
            .descendant(
              of: find.byWidget(context.widget),
              matching: find.byIcon(Icons.settings_rounded),
            )
            .evaluate()
            .isNotEmpty;
      }

      expect(reached, isTrue,
          reason: 'the settings button was never reached going right');
    });
  });
}
