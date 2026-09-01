import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/hardware_decoding.dart';

void main() {
  _zeroCopyFallback();
  tearDown(() =>
      HardwareDecoding.overrideWith(HardwareDecodingPreference.auto));

  String android(HardwareDecodingPreference preference) => HardwareDecoding
      .resolve(preference: preference, isAndroid: true, isMacOS: false);

  // The point of the whole change: the default asks for the zero-copy decoder
  // by name. `auto-safe` left the choice to mpv's whitelist, which is
  // conservative by design — so a frame the hardware had already decoded was
  // copied back through the CPU on the devices least able to afford it.
  test('Android defaults to the zero-copy decoder', () {
    expect(android(HardwareDecodingPreference.auto), 'mediacodec');
  });

  test('the Android escape hatch is the copying decoder, not software', () {
    expect(android(HardwareDecodingPreference.copy), 'mediacodec-copy');
  });

  test('Android offers three genuinely different paths', () {
    final values =
        HardwareDecodingPreference.values.map(android).toSet();
    expect(values.length, HardwareDecodingPreference.values.length);
  });

  test('macOS keeps its VideoToolbox copy on both hardware settings', () {
    for (final preference in [
      HardwareDecodingPreference.auto,
      HardwareDecodingPreference.copy,
    ]) {
      expect(
        HardwareDecoding.resolve(
            preference: preference, isAndroid: false, isMacOS: true),
        'videotoolbox-copy',
      );
    }
  });

  test('software decoding is the one unambiguous value', () {
    HardwareDecoding.overrideWith(HardwareDecodingPreference.off);
    expect(HardwareDecoding.mpvValue, 'no');
  });

  test('the compatible path always copies frames back', () {
    HardwareDecoding.overrideWith(HardwareDecodingPreference.copy);
    expect(HardwareDecoding.mpvValue, contains('copy'));
  });

  test('describe names both the choice and what mpv is told', () {
    HardwareDecoding.overrideWith(HardwareDecodingPreference.off);
    expect(HardwareDecoding.describe(), 'off → no');
  });
}

void _zeroCopyFallback() {
  group('a device that ignores the zero-copy path', () {
    test('the fast path is what Android is asked for first', () {
      expect(
        HardwareDecoding.resolve(
          preference: HardwareDecodingPreference.auto,
          isAndroid: true,
          isMacOS: false,
        ),
        'mediacodec',
      );
    });

    test('once caught decoding in software, the copy path takes over', () {
      // mpv falls back from `mediacodec` straight to the CPU, so a box whose
      // zero-copy path does not work decodes 4K in software — two frames a
      // second, and the memory that gets the app killed. The copy path is
      // still hardware.
      expect(
        HardwareDecoding.resolve(
          preference: HardwareDecodingPreference.auto,
          isAndroid: true,
          isMacOS: false,
          zeroCopyFailed: true,
        ),
        'mediacodec-copy',
      );
    });

    test('a decoder the user pinned is never second-guessed', () {
      for (final pinned in [
        HardwareDecodingPreference.copy,
        HardwareDecodingPreference.off,
      ]) {
        final before = HardwareDecoding.resolve(
          preference: pinned,
          isAndroid: true,
          isMacOS: false,
        );
        expect(
          HardwareDecoding.resolve(
            preference: pinned,
            isAndroid: true,
            isMacOS: false,
            zeroCopyFailed: true,
          ),
          before,
        );
      }
    });

    test('the observation is Android-shaped and stays there', () {
      // Nothing about a failed Android surface path says anything about macOS.
      expect(
        HardwareDecoding.resolve(
          preference: HardwareDecodingPreference.auto,
          isAndroid: false,
          isMacOS: true,
          zeroCopyFailed: true,
        ),
        'videotoolbox-copy',
      );
      expect(
        HardwareDecoding.resolve(
          preference: HardwareDecodingPreference.auto,
          isAndroid: false,
          isMacOS: false,
          zeroCopyFailed: true,
        ),
        'auto-safe',
      );
    });
  });
}
