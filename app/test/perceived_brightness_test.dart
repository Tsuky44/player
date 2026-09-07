import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/services/perceived_brightness.dart';

void main() {
  group('PerceivedBrightness', () {
    test('the top of the bar is the full backlight', () {
      expect(PerceivedBrightness.toBacklight(1), closeTo(1.0, 0.001));
      expect(PerceivedBrightness.fromBacklight(1), closeTo(1.0, 0.001));
    });

    test('halfway up the bar is a twelfth of the backlight', () {
      // The complaint this exists to answer: driven straight, half the bar was
      // half the backlight, which the eye already reads as full brightness —
      // so the whole upper half of the travel did nothing visible.
      expect(PerceivedBrightness.toBacklight(0.5), closeTo(1 / 12, 0.001));
    });

    test('the bottom of the bar dims without going dark', () {
      // A screen at a true zero is a black screen with the control that turns
      // it back up somewhere on it, invisible.
      final darkest = PerceivedBrightness.toBacklight(0);
      expect(darkest, greaterThan(0));
      expect(darkest, lessThan(0.02));
    });

    test('every step up the bar is a step up in backlight', () {
      var previous = -1.0;
      for (var i = 0; i <= 100; i++) {
        final backlight = PerceivedBrightness.toBacklight(i / 100);
        expect(backlight, greaterThanOrEqualTo(previous),
            reason: 'at ${i / 100}');
        previous = backlight;
      }
    });

    test('reading a backlight back gives the bar position that made it', () {
      // This is what opens the control on the brightness the screen is already
      // at, instead of jumping the moment it is touched.
      for (final value in [0.2, 0.35, 0.5, 0.75, 0.9]) {
        expect(
          PerceivedBrightness.fromBacklight(
            PerceivedBrightness.toBacklight(value),
          ),
          closeTo(value, 0.001),
        );
      }
    });

    test('a value outside 0..1 is brought back into it', () {
      expect(PerceivedBrightness.toBacklight(2), closeTo(1.0, 0.001));
      expect(PerceivedBrightness.toBacklight(-1),
          PerceivedBrightness.toBacklight(0));
      expect(PerceivedBrightness.fromBacklight(-1), 0);
    });
  });
}
