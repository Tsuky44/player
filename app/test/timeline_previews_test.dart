import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/screens/player/playback/timeline_previews.dart';
import 'package:onyx/screens/player/widgets/onyx/onyx_chrome_theme.dart';
import 'package:onyx/screens/player/widgets/onyx/onyx_progress_bar.dart';

/// A 1x1 transparent PNG: enough for [Image] to decode in a widget test.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const _manifest = {'interval': 10, 'count': 720, 'width': 480, 'height': 270};

void main() {
  group('TimelinePreviewManifest', () {
    test('maps a position to the nearest still, within range', () {
      final m = TimelinePreviewManifest.fromJson(_manifest);
      expect(m.indexFor(Duration.zero), 0);
      expect(m.indexFor(const Duration(seconds: 14)), 1);
      expect(m.indexFor(const Duration(seconds: 16)), 2);
      expect(m.indexFor(const Duration(hours: 5)), 719);
      expect(m.aspectRatio, closeTo(16 / 9, 0.001));
    });
  });

  group('TimelinePreviews', () {
    test('fetches only the latest position while one fetch is running',
        () async {
      final fetched = <int>[];
      final gates = <int, Completer<Uint8List>>{};
      final previews = TimelinePreviews(
        open: () async => _manifest,
        fetch: (index) {
          fetched.add(index);
          return (gates[index] = Completer<Uint8List>()).future;
        },
      );
      await previews.start();
      expect(previews.isReady, isTrue);

      previews.request(100);
      await Future<void>.delayed(Duration.zero);
      // A sweep across the bar while 100 is loading.
      for (var i = 101; i <= 150; i++) {
        previews.request(i);
      }
      gates[100]!.complete(_png);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(fetched, [100, 150]);
      // The nearest still stands in while 150 loads.
      expect(previews.imageFor(150), isNotNull);
      expect(previews.hasExact(150), isFalse);
      previews.dispose();
    });

    test('fetches the neighbours once the pointer settles', () async {
      final fetched = <int>[];
      final previews = TimelinePreviews(
        open: () async => _manifest,
        fetch: (index) async {
          fetched.add(index);
          return _png;
        },
      );
      await previews.start();
      previews.request(0);
      await pumpEventQueue();
      expect(fetched, [0, 1, 2]);
      previews.dispose();
    });

    test('gives up after repeated failures', () async {
      var calls = 0;
      final previews = TimelinePreviews(
        open: () async => _manifest,
        fetch: (index) async {
          calls++;
          throw StateError('boom');
        },
      );
      await previews.start();
      for (var i = 0; i < 20; i++) {
        previews.request(i * 10);
        await pumpEventQueue();
      }
      expect(previews.isReady, isFalse);
      expect(calls, lessThanOrEqualTo(4));
      previews.dispose();
    });

    test('stays unavailable when the server has no previews', () async {
      final previews = TimelinePreviews(
        open: () async => throw StateError('404'),
        fetch: (_) async => _png,
      );
      await previews.start();
      expect(previews.isReady, isFalse);
      previews.request(3); // no-op, no throw
      previews.dispose();
    });
  });

  testWidgets('hovering the scrubber shows the still under the pointer',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 400);
    addTearDown(tester.view.reset);

    final fetched = <int>[];
    final previews = TimelinePreviews(
      open: () async => _manifest,
      fetch: (index) async {
        fetched.add(index);
        return _png;
      },
    );
    addTearDown(previews.dispose);
    await previews.start();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 1000,
            child: OnyxProgressBar(
              progress: 0.1,
              buffered: 0.2,
              duration: const Duration(hours: 2),
              metrics: const OnyxChromeMetrics.wide(),
              onSeek: (_) {},
              previews: previews,
            ),
          ),
        ),
      ),
    ));

    final bar = tester.getRect(find.byType(OnyxProgressBar));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset(bar.left + 1, bar.center.dy));
    // Halfway along a two-hour bar: 1:00:00, still 360.
    await gesture.moveTo(bar.center);
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();

    expect(fetched.first, 360);
    expect(find.text('01:00:00'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.gaplessPlayback, isTrue);
    expect(tester.getSize(find.byType(Image)).width,
        const OnyxChromeMetrics.wide().previewWidth);
  });
}
