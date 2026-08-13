import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/app_platform.dart';

enum MacosMediaAction {
  playPause,
  play,
  pause,
  rewind,
  fastForward,
}

MacosMediaAction? parseMacosMediaAction(String? raw) {
  switch (raw) {
    case 'playPause':
      return MacosMediaAction.playPause;
    case 'play':
      return MacosMediaAction.play;
    case 'pause':
      return MacosMediaAction.pause;
    case 'rewind':
      return MacosMediaAction.rewind;
    case 'fastForward':
      return MacosMediaAction.fastForward;
    default:
      return null;
  }
}

/// macOS Control Center / Touch Bar / keyboard media keys via MPNowPlayingInfoCenter.
class MacosNowPlaying {
  static const _method = MethodChannel('project_player/now_playing');
  static const _events = EventChannel('project_player/now_playing_events');

  static Stream<MacosMediaAction>? _actionsStream;

  static bool get isSupported => AppPlatform.isMacOS;

  static Stream<MacosMediaAction> get actions {
    _actionsStream ??= _events.receiveBroadcastStream().map((event) {
      final action = parseMacosMediaAction(event as String?);
      if (action == null) {
        throw StateError('Unknown macOS media action: $event');
      }
      return action;
    });
    return _actionsStream!;
  }

  static Future<void> activate({
    required String title,
    String? artist,
    required int durationSeconds,
    required int positionSeconds,
    required bool isPlaying,
  }) {
    if (!isSupported) return Future.value();
    return _method.invokeMethod<void>('activate', _payload(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      positionSeconds: positionSeconds,
      isPlaying: isPlaying,
    ));
  }

  static Future<void> update({
    required String title,
    String? artist,
    required int durationSeconds,
    required int positionSeconds,
    required bool isPlaying,
  }) {
    if (!isSupported) return Future.value();
    return _method.invokeMethod<void>('update', _payload(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      positionSeconds: positionSeconds,
      isPlaying: isPlaying,
    ));
  }

  static Future<void> deactivate() {
    if (!isSupported) return Future.value();
    return _method.invokeMethod<void>('deactivate');
  }

  static Map<String, dynamic> _payload({
    required String title,
    String? artist,
    required int durationSeconds,
    required int positionSeconds,
    required bool isPlaying,
  }) {
    return {
      'title': title,
      if (artist != null && artist.isNotEmpty) 'artist': artist,
      'duration': durationSeconds.toDouble(),
      'elapsed': positionSeconds.toDouble(),
      'isPlaying': isPlaying,
    };
  }
}
