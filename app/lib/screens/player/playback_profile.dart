import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/app_platform.dart';

/// How much memory and GPU work a playback is allowed to spend on this device.
///
/// Every buffer in the player was sized against a desktop: 256 MB of forward
/// demuxer cache, 64 MB behind the playhead, four minutes of readahead. On a
/// machine with 16 GB that is a rounding error, and it buys a film that never
/// stutters when the Wi-Fi hiccups.
///
/// The same numbers on a streaming stick are not a large buffer, they are the
/// whole device. A Fire TV Stick 4K has 1.5 GB of RAM for Android, the launcher
/// and the app together; a 320 MB native allocation inside one app is the kind
/// of pressure that gets processes trimmed and pages evicted while a film is
/// playing — which surfaces exactly as what the desktop comments in this player
/// already describe as "periodic decode stalls", except constantly.
///
/// So the profile is resolved from what the device actually reports, once per
/// process, and every buffer is expressed as a multiple of it.
@immutable
class PlaybackProfile {
  /// mpv `demuxer-max-bytes` — the forward cache, in bytes.
  final int demuxerMaxBytes;

  /// mpv `demuxer-max-back-bytes` — the rewind window, in bytes.
  final int demuxerBackBytes;

  /// mpv `demuxer-readahead-secs`.
  final int readaheadSecs;

  /// Same three, for the HLS path: segments are short and re-fetchable, so a
  /// deep cache buys much less there than it does on a single long file.
  final int hlsDemuxerMaxBytes;
  final int hlsReadaheadSecs;

  /// Whether this device can afford mpv's per-frame HDR peak detection. It is a
  /// compute pass over every frame, and the GPU in a streaming stick is not the
  /// one that budget was written for.
  final bool allowHdrComputePeak;

  /// Human-readable reason, for the log line when a playback starts.
  final String label;

  const PlaybackProfile({
    required this.demuxerMaxBytes,
    required this.demuxerBackBytes,
    required this.readaheadSecs,
    required this.hlsDemuxerMaxBytes,
    required this.hlsReadaheadSecs,
    required this.allowHdrComputePeak,
    required this.label,
  });

  static const int _mb = 1024 * 1024;

  /// What every platform used before this existed. Still what desktops get.
  static const PlaybackProfile desktop = PlaybackProfile(
    demuxerMaxBytes: 256 * _mb,
    demuxerBackBytes: 64 * _mb,
    readaheadSecs: 240,
    hlsDemuxerMaxBytes: 100 * _mb,
    hlsReadaheadSecs: 60,
    allowHdrComputePeak: true,
    label: 'desktop',
  );

  /// A phone or tablet with room to spare. Roughly a third of the desktop
  /// buffer: enough to ride out a lift or a walk between access points, far
  /// short of what makes Android start reclaiming pages.
  static const PlaybackProfile mobile = PlaybackProfile(
    demuxerMaxBytes: 96 * _mb,
    demuxerBackBytes: 24 * _mb,
    readaheadSecs: 90,
    hlsDemuxerMaxBytes: 48 * _mb,
    hlsReadaheadSecs: 45,
    allowHdrComputePeak: true,
    label: 'mobile',
  );

  /// Streaming sticks, cheap boxes, and any Android device that calls itself
  /// low-RAM. The back buffer still covers the ten seconds the rewind button
  /// asks for, which is the one seek that must not hit the network.
  static const PlaybackProfile constrained = PlaybackProfile(
    demuxerMaxBytes: 48 * _mb,
    demuxerBackBytes: 16 * _mb,
    readaheadSecs: 45,
    hlsDemuxerMaxBytes: 24 * _mb,
    hlsReadaheadSecs: 30,
    allowHdrComputePeak: false,
    label: 'constrained',
  );

  /// Picks a profile from what the device reported.
  ///
  /// [totalMemoryMb] of 0 means the query failed. Android is assumed
  /// constrained in that case rather than generous: the devices that fail to
  /// answer are the odd cheap ones, and being wrong towards a smaller buffer
  /// costs a little rebuffering, while being wrong the other way costs the film.
  static PlaybackProfile resolve({
    required bool isAndroid,
    required bool isDesktop,
    required int totalMemoryMb,
    required bool isLowRamDevice,
    required bool isTv,
  }) {
    if (isDesktop) return desktop;
    if (!isAndroid) return mobile; // iOS, and anything else with no signal.
    if (isLowRamDevice || isTv) return constrained;
    if (totalMemoryMb <= 0) return constrained;
    if (totalMemoryMb < 3072) return constrained;
    return mobile;
  }
}

/// Resolves [PlaybackProfile] for this device, once.
abstract final class PlaybackProfiles {
  static const MethodChannel _channel = MethodChannel('onyx/device');

  static PlaybackProfile? _current;

  /// The resolved profile. [initialize] is what fills it in; before that — and
  /// on any platform that never answers — it reads as the desktop profile,
  /// which is the behaviour every platform had before this existed.
  static PlaybackProfile get current => _current ?? PlaybackProfile.desktop;

  /// Asks the platform for its memory profile and settles on one. Safe to call
  /// more than once; only the first call does any work.
  ///
  /// [isTv] comes from the caller rather than being read here, so this stays
  /// independent of the TV-mode override — a phone forced into TV mode is still
  /// a phone as far as buffers are concerned.
  static Future<void> initialize({required bool isTv}) async {
    if (_current != null) return;

    var totalMemoryMb = 0;
    var isLowRamDevice = false;

    if (AppPlatform.isAndroid) {
      try {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'memoryProfile',
        );
        totalMemoryMb = (raw?['totalMemoryMb'] as num?)?.toInt() ?? 0;
        isLowRamDevice = raw?['isLowRamDevice'] as bool? ?? false;
      } catch (error) {
        // An older install of the host app, or a platform that never registered
        // the channel. Falls through to the constrained profile, deliberately.
        debugPrint('PlaybackProfiles: memory query unavailable ($error)');
      }
    }

    _current = PlaybackProfile.resolve(
      isAndroid: AppPlatform.isAndroid,
      isDesktop: AppPlatform.isDesktop,
      totalMemoryMb: totalMemoryMb,
      isLowRamDevice: isLowRamDevice,
      isTv: isTv,
    );

    debugPrint('PlaybackProfiles: ${_current!.label} '
        '(${totalMemoryMb}MB, lowRam=$isLowRamDevice, tv=$isTv)');
  }

  @visibleForTesting
  static void overrideWith(PlaybackProfile? profile) => _current = profile;
}
