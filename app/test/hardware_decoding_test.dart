import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/hardware_decoding.dart';

void main() {
  _zeroCopyFallback();
  tearDown(
      () => HardwareDecoding.overrideWith(HardwareDecodingPreference.auto));

  String android(HardwareDecodingPreference preference) =>
      HardwareDecoding.resolve(
          preference: preference, isAndroid: true, isMacOS: false);

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
    final values = HardwareDecodingPreference.values.map(android).toSet();
    expect(values.length, HardwareDecodingPreference.values.length);
  });

  String macOS(HardwareDecodingPreference preference,
          {bool nativeOutput = true, bool zeroCopyFailed = false}) =>
      HardwareDecoding.resolve(
        preference: preference,
        isAndroid: false,
        isMacOS: true,
        macOSNativeOutput: nativeOutput,
        zeroCopyFailed: zeroCopyFailed,
      );

  // La copie renvoyait chaque image décodée par la RAM avant de la remonter
  // au GPU : ~600 Mo/s sur un 4K HDR, et un Mac qui chauffe.
  test('macOS drawing through gpu-next decodes without a copy', () {
    expect(macOS(HardwareDecodingPreference.auto), 'videotoolbox');
  });

  // Le gel de la bêta de macOS 27 a été vu sur la texture de media_kit.
  test('the media_kit texture on macOS keeps the VideoToolbox copy', () {
    expect(macOS(HardwareDecodingPreference.auto, nativeOutput: false),
        'videotoolbox-copy');
  });

  test('a Mac caught decoding in software falls back to the copy', () {
    expect(macOS(HardwareDecodingPreference.auto, zeroCopyFailed: true),
        'videotoolbox-copy');
  });

  test('the macOS escape hatch is the copy, whatever the output', () {
    for (final nativeOutput in [true, false]) {
      expect(
        macOS(HardwareDecodingPreference.copy, nativeOutput: nativeOutput),
        'videotoolbox-copy',
      );
    }
  });

  String windows(HardwareDecodingPreference preference,
          {bool zeroCopyFailed = false}) =>
      HardwareDecoding.resolve(
        preference: preference,
        isAndroid: false,
        isMacOS: false,
        isWindows: true,
        zeroCopyFailed: zeroCopyFailed,
      );

  // ADR-0095 : sans copie, mpv lisait la surface du décodeur, plus grande que
  // l'image, et laissait une bande verte en bas de certains fichiers, en 1080p
  // comme en 4K. La recopie ne sort que l'image utile.
  test('Windows never decodes without a copy, whatever the file', () {
    for (final zeroCopyFailed in [false, true]) {
      final value = windows(HardwareDecodingPreference.auto,
          zeroCopyFailed: zeroCopyFailed);
      expect(value, 'auto-copy-safe');
      expect(value, isNot(anyOf('auto', 'auto-safe', 'd3d11va')));
    }
    expect(windows(HardwareDecodingPreference.copy), 'auto-copy-safe');
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

    test('a platform with no copy fallback ignores the observation', () {
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
