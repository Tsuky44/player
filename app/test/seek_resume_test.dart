import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback/cache_pause_policy.dart';
import 'package:onyx/screens/player/playback/seek_timeline.dart';

void main() {
  group('CachePausePolicy', () {
    final t0 = DateTime(2026, 9, 15, 20);

    test('starts short, so a network that keeps up resumes quickly', () {
      expect(CachePausePolicy().waitSeconds, 2);
    });

    test('a single hiccup does not lengthen the wait', () {
      final policy = CachePausePolicy();
      expect(policy.noteUnderrun(t0), isFalse);
      expect(policy.waitSeconds, 2);
    });

    test('underruns close together lengthen the wait, up to a ceiling', () {
      final policy = CachePausePolicy();
      var now = t0;
      policy.noteUnderrun(now);
      final waits = <int>[];
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 40));
        policy.noteUnderrun(now);
        waits.add(policy.waitSeconds);
      }
      expect(waits, [5, 10, 20, 20, 20, 20]);
    });

    test('underruns far apart are separate hiccups', () {
      final policy = CachePausePolicy();
      policy.noteUnderrun(t0);
      policy.noteUnderrun(t0.add(const Duration(minutes: 2, seconds: 30)));
      expect(policy.waitSeconds, 2);
    });

    test('an empty cache mid-playback blames reception, however fast it refills',
        () {
      // The refill speed is a burst, not an average: with minutes of
      // read-ahead, the cache only empties when the average fell short.
      expect(CachePausePolicy().blamesNetwork(t0), isTrue);
      expect(
        CachePausePolicy().blamesNetwork(t0,
            lastTrackSwitch: t0.subtract(const Duration(minutes: 1))),
        isTrue,
      );
    });

    test('an empty cache right after a track switch is the switch reloading',
        () {
      expect(
        CachePausePolicy().blamesNetwork(t0,
            lastTrackSwitch: t0.subtract(const Duration(seconds: 3))),
        isFalse,
      );
    });

    test('a calm stretch brings a seek back to the short wait', () {
      final policy = CachePausePolicy();
      policy.noteUnderrun(t0);
      policy.noteUnderrun(t0.add(const Duration(seconds: 30)));
      expect(policy.waitSeconds, 5);
      expect(policy.relaxIfCalm(t0.add(const Duration(minutes: 2))), isFalse);
      expect(policy.relaxIfCalm(t0.add(const Duration(minutes: 4))), isTrue);
      expect(policy.waitSeconds, 2);
    });
  });

  group('SeekTimeline', () {
    late Duration now;
    SeekTimeline timeline(int from, int to) => SeekTimeline(
          target: Duration(seconds: to),
          startPosition: Duration(seconds: from),
          elapsed: () => now,
        );
    Duration ms(int value) => Duration(milliseconds: value);

    setUp(() => now = Duration.zero);

    test('the old clock still ticking is not a resume', () {
      final t = timeline(100, 1800);
      expect(t.notePosition(ms(100200)), isFalse);
      expect(t.notePosition(ms(100400)), isFalse);
      expect(t.resumed, isFalse);
    });

    test('the target announced, then the first frame, is not a resume yet', () {
      final t = timeline(100, 1800);
      now = ms(50);
      t.notePosition(ms(1800000));
      now = ms(900);
      expect(t.notePosition(ms(1800021)), isFalse);
    });

    test('resumes once the clock advances past the landing point', () {
      final t = timeline(100, 1800);
      t.notePosition(ms(1800000));
      now = ms(2500);
      t.notePosition(ms(1800150));
      now = ms(2700);
      expect(t.notePosition(ms(1800350)), isTrue);
      expect(t.describe(cacheAhead: const Duration(seconds: 12)),
          contains('reprise +2.70s'));
    });

    test('a keyframe landing before the target is measured from there', () {
      final t = timeline(100, 1800);
      t.notePosition(ms(1800000));
      t.notePosition(ms(1794000)); // atterri sur le point-clé
      expect(t.notePosition(ms(1794200)), isFalse);
      expect(t.notePosition(ms(1794400)), isTrue);
    });

    test('splits the picture, the cache wait and the resume', () {
      final t = timeline(100, 1800);
      t.notePosition(ms(1800000));
      now = ms(400);
      t.noteSeeking(false);
      t.notePausedForCache(true);
      now = ms(2400);
      t.notePausedForCache(false);
      t.notePosition(ms(1800100));
      now = ms(2600);
      t.notePosition(ms(1800400));
      final line = t.describe(
        cacheAhead: const Duration(seconds: 3),
        bitsPerSecond: 94000000,
      );
      expect(line, contains('image +0.40s'));
      expect(line, contains('reprise +2.60s'));
      expect(line, contains('attente cache 2.00s'));
      expect(line, contains('3s en mémoire'));
      expect(line, contains('réseau 94 Mbit/s'));
    });

    test('a seek that never resumes says so', () {
      final t = timeline(100, 1800);
      t.notePosition(ms(1800000));
      t.notePausedForCache(true);
      now = const Duration(seconds: 30);
      final line = t.describe(cacheAhead: Duration.zero);
      expect(line, contains('toujours à l\'arrêt après 30.00s'));
      expect(line, contains('attente cache 30.00s'));
    });
  });
}
