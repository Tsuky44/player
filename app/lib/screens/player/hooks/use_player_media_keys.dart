import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/macos_now_playing.dart';

/// Binds OS media keys while the player screen is active.
class PlayerMediaKeysBinding {
  final void Function() onPlayPause;
  final void Function() onRewind;
  final void Function() onFastForward;
  final bool Function() isPlaying;

  bool _attached = false;
  StreamSubscription<MacosMediaAction>? _macosSubscription;

  PlayerMediaKeysBinding({
    required this.onPlayPause,
    required this.onRewind,
    required this.onFastForward,
    required this.isPlaying,
  });

  static bool get isSupported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> attach({
    required String title,
    String? artist,
    required int durationSeconds,
    required int positionSeconds,
  }) async {
    if (!isSupported || _attached) return;
    _attached = true;

    if (Platform.isMacOS) {
      _macosSubscription ??= MacosNowPlaying.actions.listen(_onMacosAction);
      await MacosNowPlaying.activate(
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
        positionSeconds: positionSeconds,
        isPlaying: isPlaying(),
      );
    }
  }

  Future<void> detach() async {
    if (!_attached) return;
    _attached = false;

    if (Platform.isMacOS) {
      await _macosSubscription?.cancel();
      _macosSubscription = null;
      await MacosNowPlaying.deactivate();
    }
  }

  Future<void> syncSession({
    required String title,
    String? artist,
    required int durationSeconds,
    required int positionSeconds,
    required bool playing,
  }) async {
    if (!_attached) return;

    if (Platform.isMacOS) {
      await MacosNowPlaying.update(
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
        positionSeconds: positionSeconds,
        isPlaying: playing,
      );
    }
  }

  void _onMacosAction(MacosMediaAction action) {
    switch (action) {
      case MacosMediaAction.playPause:
        onPlayPause();
      case MacosMediaAction.play:
        if (!isPlaying()) onPlayPause();
      case MacosMediaAction.pause:
        if (isPlaying()) onPlayPause();
      case MacosMediaAction.rewind:
        onRewind();
      case MacosMediaAction.fastForward:
        onFastForward();
    }
  }

  /// Handles media keys that reach Flutter focus (Windows/Linux).
  KeyEventResult? handleKeyboardEvent(KeyEvent event) {
    if (Platform.isMacOS) return null;
    if (event is! KeyDownEvent) return null;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (key == LogicalKeyboardKey.mediaPlay && isPlaying()) {
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaPause && !isPlaying()) {
        return KeyEventResult.handled;
      }
      onPlayPause();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.mediaRewind) {
      onRewind();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaFastForward) {
      onFastForward();
      return KeyEventResult.handled;
    }

    return null;
  }
}
