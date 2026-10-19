import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/models.dart';
import 'package:onyx/services/api_client.dart';
import 'package:onyx/services/playback_access.dart';
import 'package:onyx/widgets/global/continue_watching_card.dart';
import 'package:onyx/widgets/global/resume_preview/hover_preview_preference.dart';
import 'package:onyx/widgets/global/resume_preview/resume_preview_anchor.dart';
import 'package:onyx/widgets/global/resume_preview/resume_preview_panel.dart';
import 'package:onyx/widgets/global/resume_preview/resume_preview_stills.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Un serveur qui refuse le ticket : l'aperçu doit alors garder l'affiche,
/// sans rien casser autour.
class _NoPreviewsApi extends ApiClient {
  int ticketRequests = 0;

  @override
  Future<PlaybackAccess> openPlaybackAccess(int mediaId,
      {bool forDownload = false}) async {
    ticketRequests++;
    throw StateError('pas de ticket dans ce test');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ResumePreviewStills.clearCacheForTest();
    HoverPreviewPreference.resetForTest();
  });

  group('resumeStillSeconds', () {
    test('ends on the frame where the viewer stopped', () {
      final seconds = resumeStillSeconds(3000, 6000);
      expect(seconds.last, 3000);
      expect(seconds.first, 3000 - 150);
      expect(seconds, orderedEquals([...seconds]..sort()));
    });

    test('an unstarted episode shows its opening, not the black first frame',
        () {
      final seconds = resumeStillSeconds(0, 2400);
      expect(seconds.first, 30);
      expect(seconds.last, 180);
    });

    test('a very short media stays inside the file', () {
      final seconds = resumeStillSeconds(10, 40);
      expect(seconds.every((s) => s >= 0 && s < 40), isTrue);
    });

    test('nothing to show without a duration', () {
      expect(resumeStillSeconds(100, 0), isEmpty);
    });
  });

  group('ResumePreviewStills', () {
    Map<String, dynamic> manifest() =>
        {'interval': 10, 'count': 600, 'width': 480, 'height': 270};

    test('fetches each still once, in order, then serves a return from memory',
        () async {
      final fetched = <int>[];
      var opens = 0;
      ResumePreviewStills build() => ResumePreviewStills(
            cacheKey: 'srv#1@600',
            seconds: const [500, 504, 550, 600],
            open: () async {
              opens++;
              return manifest();
            },
            fetch: (index) async {
              fetched.add(index);
              return Uint8List.fromList([index]);
            },
          );

      final first = build();
      await first.start();
      expect(fetched, [50, 55, 60],
          reason: 'two seconds landing on one still fetch it once');
      expect(first.images, hasLength(3));
      first.dispose();

      final second = build();
      await second.start();
      expect(opens, 1, reason: 'a second hover must not ask the server again');
      expect(second.images, hasLength(3));
      second.dispose();
    });

    test('a failure keeps what arrived and stops asking', () async {
      var calls = 0;
      final stills = ResumePreviewStills(
        cacheKey: 'srv#2@600',
        seconds: const [100, 200, 300],
        open: () async => manifest(),
        fetch: (index) async {
          calls++;
          if (calls == 2) throw StateError('extraction ratée');
          return Uint8List(1);
        },
      );
      await stills.start();
      expect(stills.images, hasLength(1));
      expect(calls, 2);
      stills.dispose();
    });

    test('closing the preview gives the playback ticket back', () async {
      var closed = 0;
      final stills = ResumePreviewStills(
        cacheKey: 'srv#3@600',
        seconds: const [100],
        open: () async => manifest(),
        fetch: (_) async => Uint8List(1),
        close: () async => closed++,
      );
      await stills.start();
      stills.dispose();
      expect(closed, 1);
    });
  });

  group('hover preview on a Continue watching card', () {
    final item = HomeMediaItem.fromJson({
      'id': 42,
      'type': 'movie',
      'title': 'Le film',
      'overview': 'Un résumé qui donne envie de reprendre.',
      'duration': 6000,
      'current_position_seconds': 600,
      'is_finished': false,
      'created_at': '2026-09-30T10:00:00Z',
    });

    Future<_NoPreviewsApi> pumpCard(
      WidgetTester tester, {
      required VoidCallback onPlay,
    }) async {
      final api = _NoPreviewsApi();
      await tester.pumpWidget(
        Provider<ApiClient>.value(
          value: api,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ContinueWatchingCard(
                  item: item,
                  onTap: (_) => onPlay(),
                  onTitleTap: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      return api;
    }

    Future<TestGesture> hoverPoster(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(ResumePreviewAnchor)));
      await tester.pump();
      return mouse;
    }

    testWidgets('a lingering mouse opens the synopsis and a resume button',
        (tester) async {
      var plays = 0;
      final api = await pumpCard(tester, onPlay: () => plays++);
      await hoverPoster(tester);

      expect(find.byType(ResumePreviewPanel), findsNothing,
          reason: 'crossing the row must not open a preview on every card');
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();

      expect(find.byType(ResumePreviewPanel), findsOneWidget);
      expect(
          find.text('Un résumé qui donne envie de reprendre.'), findsOneWidget);
      expect(api.ticketRequests, 1);

      await tester.tap(find.widgetWithText(FilledButton, 'Reprendre'));
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(find.byType(ResumePreviewPanel), findsNothing,
          reason: 'the panel must not cover the launch zoom');
    });

    testWidgets('leaving the card closes the preview', (tester) async {
      await pumpCard(tester, onPlay: () {});
      final mouse = await hoverPoster(tester);
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsOneWidget);

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(ResumePreviewAnchor.leaveGrace);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsNothing);
    });

    testWidgets('the preview keeps the ⋯ menu of the card it covers',
        (tester) async {
      await pumpCard(tester, onPlay: () {});
      await hoverPoster(tester);
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();

      final panelMenu = find.descendant(
        of: find.byType(ResumePreviewPanel),
        matching: find.byTooltip('Plus d’actions'),
      );
      expect(panelMenu, findsOneWidget);
      await tester.tap(panelMenu);
      await tester.pumpAndSettle();
      await tester.pump(ResumePreviewAnchor.menuGrace * 2);
      await tester.pumpAndSettle();

      expect(find.text("Aller à l'affiche"), findsOneWidget);
      expect(find.byType(ResumePreviewPanel), findsOneWidget,
          reason: 'the menu covering the panel is not the mouse leaving it');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(ResumePreviewAnchor.menuGrace * 2);
      await tester.pumpAndSettle();
      expect(find.text("Aller à l'affiche"), findsNothing);
      expect(find.byType(ResumePreviewPanel), findsOneWidget,
          reason: 'the mouse never left the panel');
    });

    testWidgets('closing the menu away from the panel closes the preview',
        (tester) async {
      await pumpCard(tester, onPlay: () {});
      final mouse = await hoverPoster(tester);
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(ResumePreviewPanel),
        matching: find.byTooltip('Plus d’actions'),
      ));
      await tester.pumpAndSettle();

      await mouse.moveTo(const Offset(1, 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(ResumePreviewAnchor.menuGrace);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsNothing);
    });

    testWidgets('aiming at the card ⋯ does not open the preview over it',
        (tester) async {
      await pumpCard(tester, onPlay: () {});
      final mouse = await hoverPoster(tester);
      await mouse.moveTo(tester.getCenter(find.byTooltip('Plus d’actions')));
      await tester.pump();
      await tester.pump(ResumePreviewAnchor.dwell * 2);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsNothing);

      // De retour sur l'affiche, le délai repart de zéro.
      await mouse.moveTo(tester.getCenter(find.byType(ResumePreviewAnchor)));
      await tester.pump();
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsOneWidget);
    });

    testWidgets('a click on the card cancels the pending preview',
        (tester) async {
      await pumpCard(tester, onPlay: () {});
      final mouse = await hoverPoster(tester);
      await mouse.down(tester.getCenter(find.byType(ResumePreviewAnchor)));
      await mouse.up();
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsNothing);
    });

    testWidgets('the setting turns the preview off', (tester) async {
      await HoverPreviewPreference.setEnabled(false);
      await pumpCard(tester, onPlay: () {});
      await hoverPoster(tester);
      await tester.pump(ResumePreviewAnchor.dwell);
      await tester.pumpAndSettle();
      expect(find.byType(ResumePreviewPanel), findsNothing);
    });
  });
}
