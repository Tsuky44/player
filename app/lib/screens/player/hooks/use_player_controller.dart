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

  /// Tracks probed from the original media file. Used to show consistent names
  /// in the settings sheet while transcoding.
  MediaTracks? mediaTracks;

  /// Currently selected audio stream index (within mediaTracks.audio).
  /// Relevant when transcoding, because FFmpeg only muxes one audio track.
  int _selectedAudioIndex = 0;

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

    // Load original media tracks so the settings sheet can display consistent
    // audio/subtitle names in both direct play and transcoding modes.
    try {
      mediaTracks = await apiClient.getMediaTracks(media.id);
      if (mediaTracks != null && mediaTracks!.audio.isNotEmpty) {
        _selectedAudioIndex = 0;
      }
    } catch (e) {
      print("Player: Failed to load media tracks: $e");
    }

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

  /// Quality ranking: higher number = higher quality.
  /// Direct Play (null) is ranked highest.
  static const _qualityRank = {
    '360p': 1,
    '480p': 2,
    '720p': 3,
    '1080p': 4,
  };

  int _rankOf(String? q) => q == null ? 5 : (_qualityRank[q] ?? 3);

  /// Returns true if switching from [from] to [to] is a quality downgrade.
  bool _isQualityDowngrade(String? from, String to) {
    return _rankOf(from) > _rankOf(to);
  }

  /// Switch from Direct Play to HLS transcoding at the given quality.
  /// For downgrades (e.g. Direct → 360p): pre-buffers the new stream on the
  /// server while the current one keeps playing, then switches seamlessly.
  /// For upgrades (e.g. 360p → 720p): cuts immediately with a loading spinner.
  Future<void> switchToQuality(String quality) async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == quality) return;

    final savedSeconds = position.inSeconds;

    if (_isQualityDowngrade(currentQuality, quality)) {
      await _smoothSwitchToQuality(quality, savedSeconds);
    } else {
      await _immediateSwitchToQuality(quality, savedSeconds);
    }
  }

  /// Smooth quality downgrade: start the new HLS session on the server, poll
  /// until enough segments are ready, then switch the player. The current
  /// stream keeps playing during server-side preparation — no spinner needed
  /// until the actual switch.
  Future<void> _smoothSwitchToQuality(String quality, int savedSeconds) async {
    final oldSessionId = _hlsSessionId;
    final oldMediaId = _media!.id;

    try {
      // Start new HLS session without destroying the old one yet
      final hls = await _apiClient!.startHlsSession(
        _media!.id,
        quality,
        startSeconds: savedSeconds,
        audioIndex: _selectedAudioIndex,
      );

      // Poll the variant playlist until at least 1 segment is ready (~2s)
      final mediaId = _media!.id;
      final sessionId = hls.sessionId;
      int readySegments = 0;
      for (int i = 0; i < 60; i++) {
        final playlist = await _apiClient!.fetchVariantPlaylist(mediaId, sessionId);
        if (playlist != null) {
          readySegments = _countSegments(playlist);
          if (readySegments >= 1) break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Now switch the player — show spinner only for the brief switch
      isSwitchingQuality = true;
      _onQualitySwitchingChanged?.call();

      // Destroy old session (fire-and-forget)
      if (oldSessionId != null) {
        _apiClient!.destroyHlsSession(oldMediaId, oldSessionId);
      }

      _hlsSessionId = hls.sessionId;
      currentQuality = quality;
      _hlsStartOffset = savedSeconds;

      final tmpFile = await _writeTempPlaylist(hls.playlistContent);
      await _applyHlsPlayerProperties();
      await player.open(mk.Media(tmpFile.path), play: true);

      _forceDuration(hls.totalDuration);
      _hideLoadingAfterBuffer();
    } catch (e) {
      print("Player: Failed smooth quality switch: $e");
      isSwitchingQuality = false;
      _onQualitySwitchingChanged?.call();
    }
  }

  /// Immediate quality switch (for upgrades or same-level changes).
  /// Shows spinner immediately and cuts to the new stream.
  Future<void> _immediateSwitchToQuality(String quality, int savedSeconds) async {
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    _destroyHlsSessionAsync();

    try {
      final hls = await _apiClient!.startHlsSession(
        _media!.id,
        quality,
        startSeconds: savedSeconds,
        audioIndex: _selectedAudioIndex,
      );
      _hlsSessionId = hls.sessionId;
      currentQuality = quality;
      _hlsStartOffset = savedSeconds;

      final tmpFile = await _writeTempPlaylist(hls.playlistContent);
      await _applyHlsPlayerProperties();
      await player.open(mk.Media(tmpFile.path), play: true);

      _forceDuration(hls.totalDuration);
      _hideLoadingAfterBuffer();
    } catch (e) {
      print("Player: Failed to start HLS session: $e");
      currentQuality = null;
      _hlsSessionId = null;
      isSwitchingQuality = false;
      _onQualitySwitchingChanged?.call();
    }
  }

  /// Count the number of segment lines in an M3U8 variant playlist.
  int _countSegments(String playlist) {
    int count = 0;
    for (final line in playlist.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      count++;
    }
    return count;
  }

  /// Switch back to Direct Play from HLS transcoding.
  Future<void> switchToDirectPlay() async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == null) return;

    final savedSeconds = position.inSeconds;
    print("Player: switchToDirectPlay: savedSeconds = $savedSeconds");
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    await _destroyHlsSession();

    currentQuality = null;
    _hlsStartOffset = 0;
    duration = Duration.zero;

    final streamUrl = _apiClient!.getStreamUrl(_media!.id);
    print("Player: switchToDirectPlay: streamUrl = $streamUrl");

    // Open direct play with play:true to trigger buffering/decoding.
    // The loading spinner covers the UI so the transition is invisible.
    await player.open(mk.Media(streamUrl), play: true);

    // Wait for the buffering cycle (loading started -> loading finished).
    // This guarantees MPV has established the connection, parsed headers,
    // and is actively playing, meaning the stream is 100% ready and seekable.
    try {
      print("Player: switchToDirectPlay: Waiting for buffering to start...");
      if (!player.state.buffering) {
        await player.stream.buffering
            .firstWhere((isBuffering) => isBuffering)
            .timeout(const Duration(seconds: 3));
      }
      print("Player: switchToDirectPlay: Buffering started. Waiting for buffering to finish...");
      await player.stream.buffering
          .firstWhere((isBuffering) => !isBuffering)
          .timeout(const Duration(seconds: 7));
      print("Player: switchToDirectPlay: Buffering finished. Stream is fully ready.");
    } catch (e) {
      print("Player: switchToDirectPlay: Buffering sync timeout or error: $e");
      // Fallback: wait a short safe delay if buffering events were missed
      await Future.delayed(const Duration(milliseconds: 1200));
    }

    if (savedSeconds > 0 && !_disposed) {
      print("Player: switchToDirectPlay: Seeking to target $savedSeconds");
      await player.seek(Duration(seconds: savedSeconds));
      // Give the player a tiny window to register the seek command before hiding loader
      await Future.delayed(const Duration(milliseconds: 400));
    }

    isSwitchingQuality = false;
    _onQualitySwitchingChanged?.call();
    print("Player: switchToDirectPlay: Switch completed successfully!");
  }

  /// Current selected audio index (within mediaTracks.audio). 0 by default.
  int get selectedAudioIndex => _selectedAudioIndex;

  /// Select a different audio track. In transcoding mode this recreates the
  /// HLS session with the new audio_index, because FFmpeg only muxes one
  /// audio stream. In direct play this is a no-op; media_kit handles the switch
  /// directly via setAudioTrack.
  Future<void> switchAudioTrack(int index) async {
    if (_media == null || _apiClient == null) return;
    if (index < 0) return;
    if (mediaTracks != null && index >= mediaTracks!.audio.length) return;

    _selectedAudioIndex = index;

    if (currentQuality != null) {
      // Recreate the HLS session at the current position so the new audio
      // stream is transcoded from now on.
      await reloadHlsAtPosition(position.inSeconds);
    }
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
        audioIndex: _selectedAudioIndex,
      );
      _hlsSessionId = hls.sessionId;
      _hlsStartOffset = newPositionSeconds;

      final tmpFile = await _writeTempPlaylist(hls.playlistContent);
      await _applyHlsPlayerProperties();
      // Open with play:true so MPV handles buffering and auto-plays when ready
      await player.open(mk.Media(tmpFile.path), play: true);

      // Force the full media duration so the timeline matches direct play
      _forceDuration(hls.totalDuration);

      // No seek needed — the HLS stream starts at newPositionSeconds (via FFmpeg -ss).
      _hideLoadingAfterBuffer();
    } catch (e) {
      print("Player: Failed to reload HLS session: $e");
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

  /// Wait for buffering to actually start (true) then stop (false) before
  /// hiding the loading indicator. This prevents the spinner from disappearing
  /// too early when the player hasn't started buffering yet.
  void _hideLoadingAfterBuffer() {
    StreamSubscription? sub;
    bool sawBuffering = false;
    sub = player.stream.buffering.listen((isBuffering) {
      if (isBuffering) {
        sawBuffering = true;
      } else if (sawBuffering) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
        sub?.cancel();
      }
    });
    // Safety timeout: hide loading after 15s even if buffering events were missed
    Timer(const Duration(seconds: 15), () {
      sub?.cancel();
      if (isSwitchingQuality) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
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
