import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/models/player_layout.dart';
import 'package:onyx/utils/format.dart';

void main() {
  group('fixed chrome round-trips through the config JSON', () {
    test('a fixed preset keeps its chrome id across encode/decode', () {
      final config = PlayerLayoutConfig.fixed(FixedChromeId.emby);
      final decoded = PlayerLayoutConfig.decode(config.encode());
      expect(decoded.fixedChrome, FixedChromeId.emby);
      expect(decoded.isFixedChrome, isTrue);
    });

    test('a modular preset stays modular', () {
      final decoded = PlayerLayoutConfig.decode(
        PlayerLayoutConfig.standard().encode(),
      );
      expect(decoded.fixedChrome, isNull);
      expect(decoded.isFixedChrome, isFalse);
    });

    test('a config written before fixed chromes existed decodes as modular', () {
      final legacy = PlayerLayoutConfig.standard().toJson()
        ..remove('fixed_chrome');
      expect(PlayerLayoutConfig.fromJson(legacy).fixedChrome, isNull);
    });

    test('an unknown chrome id degrades to the modular layout', () {
      final json = PlayerLayoutConfig.standard().toJson()
        ..['fixed_chrome'] = 'chrome-from-a-newer-client';
      final decoded = PlayerLayoutConfig.fromJson(json);
      expect(decoded.fixedChrome, isNull);
      expect(decoded.controls, isNotEmpty,
          reason: 'the fallback layout must still be usable');
    });

    test('a fixed preset carries a usable fallback layout for old clients', () {
      // Older clients ignore `fixed_chrome` entirely, so what they render is
      // whatever `controls` holds — it must not be empty.
      expect(PlayerLayoutConfig.fixed(FixedChromeId.emby).controls, isNotEmpty);
    });

    test('copyWith keeps the chrome unless explicitly cleared', () {
      final fixed = PlayerLayoutConfig.fixed(FixedChromeId.emby);
      expect(fixed.copyWith(tapToTogglePlayback: true).fixedChrome,
          FixedChromeId.emby);
      expect(fixed.copyWith(clearFixedChrome: true).fixedChrome, isNull);
    });
  });

  group('formatEndClock', () {
    final now = DateTime(2026, 8, 11, 16, 18, 27);

    test('adds the remaining time to the wall clock', () {
      // 16:18:27 + 3:12:33 = 19:31:00 — the readout in the Emby player.
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
