import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';

class PlayerController {
  late final mk.Player player;
  late final VideoController videoController;

  bool isInitialized = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isDraggingSlider = false;
  double dragValue = 0.0;

  /// True while switching quality or reloading HLS session (for UI loading indicator).
  bool isSwitchingQuality = false;

  /// Offset in seconds: when transcoding, the HLS stream starts at position 0
  /// but corresponds to this offset in the original media. Used to display the
  /// correct absolute position and compute seek targets.
  int _hlsStartOffset = 0;
  int get hlsStartOffset => _hlsStartOffset;

  /// Current transcoding quality. null = Direct Play, "720p" = transcoding.
  String? currentQuality;
  /// Active HLS session ID (set when transcoding starts).
  String? _hlsSessionId;
  /// Media + API client references for quality switching.
  Media? _media;
  ApiClient? _apiClient;
  VoidCallback? _onDurationChanged;
  VoidCallback? _onQualitySwitchingChanged;

  Timer? _heartbeatTimer;

  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _videoParamsSubscription;
  bool _disposed = false;

  /// Aspect ratio of the current video (width / height).
  /// Used for adaptive display mode calculations.
  double videoAspectRatio = 16 / 9;

  PlayerController() {
    player = mk.Player();
    videoController = VideoController(player);
  }

  Future<void> init({
    required Media media,
    required ApiClient apiClient,
    required VoidCallback onCompleted,
    required VoidCallback onPositionChanged,
    required VoidCallback onDurationChanged,
    VoidCallback? onQualitySwitchingChanged,
  }) async {
    // Apply MPV properties
    try {
      await (player.platform as dynamic).setProperty('cache-secs', '1');
      await (player.platform as dynamic).setProperty('demuxer-max-bytes', '52428800');
      await (player.platform as dynamic).setProperty('demuxer-readahead-secs', '120');
      await (player.platform as dynamic).setProperty('hwdec', 'auto');
      await (player.platform as dynamic).setProperty('sub-visibility', 'no');
      await (player.platform as dynamic).setProperty('sub-auto', 'no');
    } catch (e) {
      print("Player: Failed to apply native MPV properties: $e");
    }

    _positionSubscription = player.stream.position.listen((pos) {
      if (_disposed) return;
      // In HLS mode, add the start offset so the displayed position matches
      // the absolute position in the original media.
      if (currentQuality != null && _hlsStartOffset > 0) {
        position = pos + Duration(seconds: _hlsStartOffset);
      } else {
        position = pos;
      }
      onPositionChanged();
    });

    _durationSubscription = player.stream.duration.listen((dur) {
      if (_disposed) return;
      // In HLS transcoding mode, ignore MPV's reported duration (which grows
      // as segments are produced) — we force the full media duration instead.
      if (currentQuality != null) return;
      duration = dur;
      onDurationChanged();
    });

    _completedSubscription = player.stream.completed.listen((completed) {
      if (_disposed) return;
      if (completed) onCompleted();
    });

    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      if (_disposed) return;
      final aspect = params.aspect;
      if (aspect != null && aspect > 0) {
        videoAspectRatio = aspect;
      }
    });

    _media = media;
    _apiClient = apiClient;
    _onDurationChanged = onDurationChanged;
    _onQualitySwitchingChanged = onQualitySwitchingChanged;

    final streamUrl = apiClient.getStreamUrl(media.id);
    await player.open(mk.Media(streamUrl), play: false);
  }

  void startHeartbeat({
    required int mediaId,
    required ApiClient apiClient,
  }) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (player.state.playing) {
        _sendProgress(mediaId: mediaId, apiClient: apiClient, isFinished: false);
      }
    });
  }

  Future<void> _sendProgress({
    required int mediaId,
    required ApiClient apiClient,
    required bool isFinished,
  }) async {
    final posSeconds = position.inSeconds;
    final durSeconds = duration.inSeconds;
    if (posSeconds <= 0 || durSeconds <= 0) return;

    try {
      await apiClient.sendProgress(
        mediaId: mediaId,
        currentPositionSeconds: posSeconds,
        duration: durSeconds,
        isFinished: isFinished,
      );
    } catch (e) {
      print("Player: Failed to sync progress: $e");
    }
  }

  Future<void> finishPlayback({
    required int mediaId,
    required ApiClient apiClient,
    bool isFinished = false,
  }) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final posSeconds = position.inSeconds;
    final durSeconds = duration.inSeconds;

    if (posSeconds > 0 && durSeconds > 0) {
      bool finalIsFinished = isFinished;
      if (!finalIsFinished) {
        final percentWatched = (posSeconds / durSeconds) * 100;
        if (percentWatched >= 90.0) {
          finalIsFinished = true;
        }
      }
      await _sendProgress(
        mediaId: mediaId,
        apiClient: apiClient,
        isFinished: finalIsFinished,
      );
    }
  }

  /// Switch from Direct Play to HLS transcoding at the given quality.
  /// Saves the current position, starts an HLS session (fetching the session ID),
  /// writes the master playlist to a temp file, opens it, and seeks to the saved position.
  Future<void> switchToQuality(String quality) async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == quality) return;

    final savedSeconds = player.state.position.inSeconds;
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    // Fire-and-forget: destroy previous session in background, don't block new session
    _destroyHlsSessionAsync();

    try {
      final hls = await _apiClient!.startHlsSession(
        _media!.id,
        quality,
        startSeconds: savedSeconds,
      );
      _hlsSessionId = hls.sessionId;
      currentQuality = quality;
      _hlsStartOffset = savedSeconds;

      // Write master playlist to temp file so MPV can open it
      final tmpFile = await _writeTempPlaylist(hls.playlistContent);
      await _applyHlsPlayerProperties();
      await player.open(mk.Media(tmpFile.path), play: false);

      // Force the full media duration so the timeline matches direct play
      _forceDuration(hls.totalDuration);

      // No seek needed — the HLS stream starts at savedSeconds (via FFmpeg -ss).
      // Just wait for the stream to be ready and play.
      _playAfterLoad();
    } catch (e) {
      print("Player: Failed to start HLS session: $e");
      currentQuality = null;
      _hlsSessionId = null;
    } finally {
      isSwitchingQuality = false;
      _onQualitySwitchingChanged?.call();
    }
  }

  /// Switch back to Direct Play from HLS transcoding.
  Future<void> switchToDirectPlay() async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == null) return;

    final savedSeconds = player.state.position.inSeconds;

    await _destroyHlsSession();

    currentQuality = null;
    _hlsStartOffset = 0;
    final streamUrl = _apiClient!.getStreamUrl(_media!.id);
    await player.open(mk.Media(streamUrl), play: false);

    _seekAfterLoad(savedSeconds);
  }

  /// Reload the HLS session at a new position (used on large seeks >30s
  /// while in transcoding mode, since old segments are deleted from the sliding window).
  Future<void> reloadHlsAtPosition(int newPositionSeconds) async {
    if (_media == null || _apiClient == null || currentQuality == null) return;

    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();
    // Fire-and-forget: destroy previous session in background
    _destroyHlsSessionAsync();

    try {
      final hls = await _apiClient!.startHlsSession(
        _media!.id,
        currentQuality!,
        startSeconds: newPositionSeconds,
      );
      _hlsSessionId = hls.sessionId;
      _hlsStartOffset = newPositionSeconds;

      final tmpFile = await _writeTempPlaylist(hls.playlistContent);
      await _applyHlsPlayerProperties();
      await player.open(mk.Media(tmpFile.path), play: false);

      // Force the full media duration so the timeline matches direct play
      _forceDuration(hls.totalDuration);

      // No seek needed — the HLS stream starts at newPositionSeconds (via FFmpeg -ss).
      _playAfterLoad();
    } catch (e) {
      print("Player: Failed to reload HLS session: $e");
    } finally {
      isSwitchingQuality = false;
      _onQualitySwitchingChanged?.call();
    }
  }

  /// Write the master playlist content to a temporary file.
  Future<File> _writeTempPlaylist(String content) async {
    final tmpDir = Directory.systemTemp;
    final file = File('${tmpDir.path}/hls_master_${DateTime.now().millisecondsSinceEpoch}.m3u8');
    await file.writeAsString(content);
    return file;
  }

  /// Apply MPV properties specific to HLS playback for proper timeline handling.
  Future<void> _applyHlsPlayerProperties() async {
    try {
      await (player.platform as dynamic).setProperty('force-seekable', 'yes');
      await (player.platform as dynamic).setProperty('cache', 'yes');
      await (player.platform as dynamic).setProperty('demuxer-seekable-cache', 'yes');
      await (player.platform as dynamic).setProperty('demuxer-max-bytes', '104857600');
      await (player.platform as dynamic).setProperty('demuxer-readahead-secs', '60');
    } catch (_) {}
  }

  /// Force the total media duration on the player so the timeline shows the
  /// full media length even though HLS only has a few segments transcoded.
  void _forceDuration(double totalDurationSeconds) {
    if (totalDurationSeconds <= 0) return;
    duration = Duration(seconds: totalDurationSeconds.round());
    try {
      (player.platform as dynamic).setProperty('length', totalDurationSeconds.toStringAsFixed(3));
    } catch (_) {}
    _onDurationChanged?.call();
  }

  /// Wait for the stream to be ready (buffering=false), then start playing.
  /// Used after opening an HLS stream that already starts at the right position.
  void _playAfterLoad() {
    StreamSubscription? sub;
    sub = player.stream.buffering.listen((isBuffering) {
      if (!isBuffering) {
        player.play();
        sub?.cancel();
      }
    });
  }

  /// Seeks to the saved position after a source switch.
  /// Listens for the first buffering=false event, then seeks.
  /// Used for Direct Play mode where the stream starts at position 0.
  void _seekAfterLoad(int targetSeconds) {
    StreamSubscription? sub;
    sub = player.stream.buffering.listen((isBuffering) {
      if (!isBuffering && targetSeconds > 0) {
        player.seek(Duration(seconds: targetSeconds));
        sub?.cancel();
      }
    });
  }

  /// Destroy the current HLS session on the server (if any).
  Future<void> _destroyHlsSession() async {
    if (_hlsSessionId == null || _media == null || _apiClient == null) return;

    await _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    _hlsSessionId = null;
  }

  /// Fire-and-forget version of _destroyHlsSession — clears the session ID
  /// immediately and sends the destroy request in the background without blocking.
  void _destroyHlsSessionAsync() {
    if (_hlsSessionId == null || _media == null || _apiClient == null) return;

    final oldSessionId = _hlsSessionId!;
    final oldMediaId = _media!.id;
    _hlsSessionId = null;

    // Fire-and-forget
    _apiClient!.destroyHlsSession(oldMediaId, oldSessionId);
  }

  // Cancel streams without disposing the player (use before navigation)
  void cancelStreams() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription = null;
    _completedSubscription = null;
    _videoParamsSubscription = null;
    // Destroy HLS session if active (fire-and-forget since cancelStreams is sync)
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
  }

  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    // Destroy HLS session if active (fire-and-forget since dispose is sync)
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
    player.dispose();
  }
}
