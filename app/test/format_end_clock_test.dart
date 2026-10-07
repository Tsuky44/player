import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/utils/format.dart';

void main() {
  group('formatEndClock', () {
    final now = DateTime(2026, 8, 11, 16, 18, 27);

    test('adds the remaining time to the wall clock', () {
      // 16:18:27 + 3:12:33 = 19:31:00 — the Chrome Onyx readout.
      expect(formatEndClock(3 * 3600 + 12 * 60 + 33, now: now), '19:31');
    });

    test('pads both fields to two digits', () {
      expect(formatEndClock(0, now: DateTime(2026, 8, 11, 9, 5)), '09:05');
    });

    test('rolls over midnight', () {
      expect(formatEndClock(2 * 3600, now: DateTime(2026, 8, 11, 23, 30)),
          '01:30');
    });

    test('treats a negative remainder as zero', () {
      expect(formatEndClock(-90, now: now), '16:18');
    });
  });
}
