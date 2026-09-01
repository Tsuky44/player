import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../utils/app_platform.dart';

/// A libmpv instance together with the video texture it renders into.
///
/// The two are created as a pair and stay a pair for their whole life: a
/// [VideoController] is bound to the player it was constructed with and cannot
/// be moved to another one.
class PlayerEngine {
  final mk.Player player;
  final VideoController videoController;

  /// The unload issued when this engine was parked, while it is still running.
  ///
  /// Whoever takes the engine out of the pool has to wait for this before
  /// opening anything on it. It used to be fire-and-forget, and an unload that
  /// landed *after* the next file was opened unloaded that file instead — mpv
  /// sitting idle behind a spinner that never ends, on a playback that looked
  /// like it had started. Rare on a desktop, where the stop is done long before
  /// anyone picks the next episode; not rare on a television, where the stop is
  /// slower and the next media is one press of OK away.
  Future<void>? pendingStop;

  PlayerEngine._(this.player, this.videoController);

  factory PlayerEngine._create() {
    final player = mk.Player();
    return PlayerEngine._(player, VideoController(player));
  }

  /// Waits out the parked unload, if there is one. Idempotent.
  Future<void> settle() async {
    final pending = pendingStop;
    if (pending == null) return;
    await pending;
    // Only clear what we waited on: a stop issued in the meantime is not ours.
    if (identical(pendingStop, pending)) pendingStop = null;
  }
}

/// Keeps one idle [PlayerEngine] alive between playbacks.
///
/// Building an engine is the expensive, invisible part of opening a media:
/// libmpv has to create its context, the video controller has to allocate its
/// texture and negotiate the render path with the platform. None of that
/// depends on which file is about to play, and none of it has to happen while
/// the user is staring at a spinner — so it is done once, off the critical
/// path, and the same engine is handed to every playback that follows.
///
/// At most one engine is idle at a time. A second one is only ever built when a
/// playback starts while the previous screen still holds its engine (the
/// episode auto-advance builds the new screen before the old one is disposed);
/// whichever comes back last is the one kept warm.
class PlayerEnginePool {
  PlayerEnginePool._();

  static PlayerEngine? _idle;

  /// Takes the warm engine, or builds one when the pool is empty.
  static PlayerEngine acquire() {
    final warm = _idle;
    if (warm != null) {
      _idle = null;
      return warm;
    }
    return PlayerEngine._create();
  }

  /// Gives an engine back after a playback ends.
  static void release(PlayerEngine engine) {
    if (_idle != null) {
      // Already holding one — a second idle engine is memory nobody asked for.
      // `dispose` stops the player on its way out, so this covers the unload
      // too; racing it with a separate `stop` would only produce a rejected
      // command against an instance that is already gone.
      unawaited(engine.player.dispose().catchError((_) {}));
      return;
    }

    // `stop` is not optional housekeeping: an engine parked with a file still
    // loaded would keep its HTTP connection open and keep reading the stream
    // for as long as it sits in the pool. It also clears the position,
    // duration and track list, so the next media cannot inherit a stale state
    // through the reused instance. Volume and playback rate deliberately
    // survive it — they belong to the person watching, not to the file.
    //
    // Kept rather than dropped: the next playback has to wait for it. See
    // [PlayerEngine.pendingStop].
    engine.pendingStop = engine.player.stop().catchError((_) {});
    _idle = engine;
  }

  /// Builds the first engine ahead of time, so the first playback of the
  /// session is as fast as the ones after it.
  ///
  /// Call once the app is idle: this competes with whatever is loading at
  /// startup, and it exists precisely to move the cost somewhere the user is
  /// not waiting.
  static void prewarm() {
    // The web backend is an HTMLVideoElement — there is no mpv context to
    // build, so there is nothing to gain and a stray <video> to avoid.
    if (AppPlatform.isWeb) return;
    if (_idle != null) return;
    try {
      _idle = PlayerEngine._create();
    } catch (e) {
      // A player that cannot be built ahead of time will simply be built on
      // demand; failing to prewarm must never stop the app from starting.
      debugPrint('PlayerEnginePool: prewarm failed: $e');
    }
  }
}
