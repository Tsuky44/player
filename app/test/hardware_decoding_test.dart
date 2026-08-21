import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/hardware_decoding.dart';

void main() {
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
