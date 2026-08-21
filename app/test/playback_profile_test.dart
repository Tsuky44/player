import 'package:flutter_test/flutter_test.dart';

import 'package:onyx/screens/player/playback_profile.dart';

void main() {
  const mb = 1024 * 1024;

  PlaybackProfile resolve({
    bool isAndroid = true,
    bool isDesktop = false,
    int totalMemoryMb = 8192,
    bool isLowRamDevice = false,
    bool isTv = false,
  }) =>
      PlaybackProfile.resolve(
        isAndroid: isAndroid,
        isDesktop: isDesktop,
        totalMemoryMb: totalMemoryMb,
        isLowRamDevice: isLowRamDevice,
        isTv: isTv,
      );

  test('a desktop keeps the buffers it always had', () {
    final profile = resolve(isAndroid: false, isDesktop: true);
    expect(profile.demuxerMaxBytes, 256 * mb);
    expect(profile.demuxerBackBytes, 64 * mb);
    expect(profile.readaheadSecs, 240);
  });

  // A Fire TV Stick 4K has 1.5 GB of RAM for Android, its launcher and this app
  // together. The desktop profile asks for a fifth of that in one native
  // allocation, which is the pressure — not the decode — that stalls playback.
  test('a television takes the constrained profile whatever it reports', () {
    final profile = resolve(totalMemoryMb: 2048, isTv: true);
    expect(profile, same(PlaybackProfile.constrained));
    expect(profile.demuxerMaxBytes + profile.demuxerBackBytes,
        lessThan(96 * mb));
  });

  test('a low-RAM device is constrained even off a television', () {
    expect(resolve(totalMemoryMb: 6144, isLowRamDevice: true),
        same(PlaybackProfile.constrained));
  });

  test('a modern phone gets the middle profile', () {
    expect(resolve(totalMemoryMb: 8192), same(PlaybackProfile.mobile));
  });

  test('a small phone is constrained', () {
    expect(resolve(totalMemoryMb: 2048), same(PlaybackProfile.constrained));
  });

  // Being wrong towards a smaller buffer costs a little rebuffering; being wrong
  // the other way costs the film.
  test('an unanswered memory query is treated as constrained', () {
    expect(resolve(totalMemoryMb: 0), same(PlaybackProfile.constrained));
  });

  test('iOS falls back to the mobile profile, never the desktop one', () {
    expect(resolve(isAndroid: false, totalMemoryMb: 0),
        same(PlaybackProfile.mobile));
  });

  test('the rewind window still covers the back-10s button everywhere', () {
    // 16 MiB is about four seconds of a 30 Mbps remux, and a good deal more of
    // anything a constrained device will actually be sent.
    for (final profile in [
      PlaybackProfile.desktop,
      PlaybackProfile.mobile,
      PlaybackProfile.constrained,
    ]) {
      expect(profile.demuxerBackBytes, greaterThanOrEqualTo(16 * mb),
          reason: profile.label);
      expect(profile.demuxerMaxBytes,
          greaterThan(profile.demuxerBackBytes),
          reason: profile.label);
    }
  });

  test('only the constrained profile gives up HDR peak detection', () {
    expect(PlaybackProfile.desktop.allowHdrComputePeak, isTrue);
    expect(PlaybackProfile.mobile.allowHdrComputePeak, isTrue);
    expect(PlaybackProfile.constrained.allowHdrComputePeak, isFalse);
  });
}
