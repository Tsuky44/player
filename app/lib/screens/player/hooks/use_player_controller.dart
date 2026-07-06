import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import '../../../models/models.dart';
import '../../../services/api_client.dart';
import '../player_playback_preferences.dart';

/// Orchestrates playback, quality/audio/subtitle switching and the Direct Play
/// ↔ HLS transitions.
///
/// Track model (the "Unified Strategy"): the canonical audio/subtitle list comes
/// from the server's /api/media/:id/tracks endpoint and is used by the UI in
/// BOTH modes. Selections are expressed as indices into that canonical list and
/// re-applied automatically every time the underlying media is (re)opened.
///
///   - Audio: every track is exposed as an HLS rendition while transcoding (and
///     natively in Direct Play), so switching languages is instant — no session
///     rebuild.
///   - Subtitles: clean external .vtt files served by the backend (local sidecar
///     files or OpenSubtitles downloads), attached via SubtitleTrack.uri and
///     selected by language code. They work identically in both modes; the only
///     HLS-specific concern is a time-shift so cues align with the stream offset.
class PlayerController {
  late final mk.Player player;
  late final VideoController videoController;

  bool isInitialized = false;
  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isDraggingSlider = false;
  double dragValue = 0.0;

  /// True while switching quality / rebuilding the HLS session (drives the UI spinner).
  bool isSwitchingQuality = false;

  /// In HLS mode the stream timeline resets to 0 at this offset (seconds) into
  /// the original media. Used to display the absolute position and to compute
  /// seek targets. 0 in Direct Play.
  int _hlsStartOffset = 0;
  int get hlsStartOffset => _hlsStartOffset;

  /// Current transcoding quality. null = Direct Play.
  String? currentQuality;
  String? _hlsSessionId;

  Media? _media;
  ApiClient? _apiClient;
  int _knownDurationSeconds = 0;
  VoidCallback? _onDurationChanged;
  VoidCallback? _onQualitySwitchingChanged;
  VoidCallback? _onTracksChanged;
  VoidCallback? _onPlayingChanged;

  /// Guards the one-shot background subtitle extraction kicked off on start.
  bool _autoExtractStarted = false;

  /// True while a subtitle extraction request is in flight on the server.
  bool _isExtractingSubtitles = false;
  bool get isExtractingSubtitles => _isExtractingSubtitles;

  /// Polls the tracks endpoint while subtitles are still being extracted so the
  /// menu and the active selection update without an HLS reload.
  Timer? _subtitleWatchTimer;

  /// Notifies widgets (e.g. the settings overlay) that [mediaTracks] changed.
  final _tracksStreamController = StreamController<void>.broadcast();
  Stream<void> get tracksStream => _tracksStreamController.stream;

  int? get mediaId => _media?.id;

  /// Canonical track list from the server (consistent across modes).
  MediaTracks? mediaTracks;

  /// Selected audio track = index into [mediaTracks.audio] (== FFmpeg 0:a:N).
  int _selectedAudioIndex = 0;
  int get selectedAudioIndex => _selectedAudioIndex;

  /// Selected subtitle language code, or null for "off". This is the single
  /// source of truth across modes: in Direct Play it maps to an embedded MKV
  /// track, in HLS to an external .vtt — so the choice carries over invisibly.
  String? _selectedSubtitleLang;
  String? get selectedSubtitleLang => _selectedSubtitleLang;

  /// In Direct Play the user can pick an embedded track that has no clean
  /// language tag (e.g. "Anglais SDH"); we remember its mpv id to re-select it
  /// exactly after a reload, falling back to language matching otherwise.
  String? _selectedInternalSubId;

  /// When true, subtitles were explicitly disabled and must stay off until the
  /// user turns them on (or they are inherited from the previous episode).
  bool _subtitlesExplicitlyOff = true;

  /// Set when opening with inherited audio/subtitle choices (auto-advance).
  bool _pendingPreferenceReapply = false;

  PlayerPlaybackPreferences exportPreferences() {
    if (_subtitlesExplicitlyOff) {
      return PlayerPlaybackPreferences(
        audioIndex: _selectedAudioIndex,
        subtitlesOff: true,
      );
    }

    final track = player.state.track.subtitle;
    final subsActive = track.id != 'no' &&
        track.id != 'auto' &&
        track.id.isNotEmpty;

    if (!subsActive) {
      return PlayerPlaybackPreferences(
        audioIndex: _selectedAudioIndex,
        subtitlesOff: true,
      );
    }

    return PlayerPlaybackPreferences(
      audioIndex: _selectedAudioIndex,
      subtitleLang: _selectedSubtitleLang ?? _normalizeLang(track.language),
      internalSubId: _selectedInternalSubId ?? track.id,
      subtitlesOff: false,
    );
  }

  void _applyInheritedPreferences(PlayerPlaybackPreferences prefs) {
    final audioCount = mediaTracks?.audio.length ?? 0;
    if (audioCount > 0) {
      _selectedAudioIndex = prefs.audioIndex.clamp(0, audioCount - 1);
    } else {
      _selectedAudioIndex = prefs.audioIndex;
    }

    _subtitlesExplicitlyOff = prefs.subtitlesOff;
    if (prefs.subtitlesOff) {
      _selectedSubtitleLang = null;
      _selectedInternalSubId = null;
    } else {
      _selectedSubtitleLang = prefs.subtitleLang;
      _selectedInternalSubId = prefs.internalSubId;
    }
  }

  Timer? _heartbeatTimer;
  Timer? _deferredSubtitleExtractTimer;
  /// Delay subtitle extraction so FFmpeg on the server does not compete with
  /// the HTTP stream for disk I/O during the first minutes of Direct Play.
  static const _subtitleExtractDelay = Duration(seconds: 90);
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _videoParamsSubscription;
  StreamSubscription? _reapplySubscription;
  bool _disposed = false;

  /// Aspect ratio of the current video (width / height).
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
    VoidCallback? onPlayingChanged,
    VoidCallback? onQualitySwitchingChanged,
    VoidCallback? onTracksChanged,
    PlayerPlaybackPreferences? inheritedPreferences,
    int knownDurationSeconds = 0,
  }) async {
    try {
      await _applyDirectPlayPlayerProperties();
    } catch (e) {
      debugPrint("Player: failed to apply native MPV properties: $e");
    }

    _positionSubscription = player.stream.position.listen((pos) {
      if (_disposed) return;
      position = (currentQuality != null && _hlsStartOffset > 0)
          ? pos + Duration(seconds: _hlsStartOffset)
          : pos;
      onPositionChanged();
    });

    _playingSubscription = player.stream.playing.listen((playing) {
      if (_disposed) return;
      _setPlaying(playing);
    });

    isPlaying = player.state.playing;

    _durationSubscription = player.stream.duration.listen((dur) {
      if (_disposed) return;
      // While transcoding we force the full media duration (MPV's reported
      // duration only covers the segments produced so far).
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
      if (aspect != null && aspect > 0) videoAspectRatio = aspect;
    });

    _media = media;
    _apiClient = apiClient;
    _knownDurationSeconds = knownDurationSeconds > 0
        ? knownDurationSeconds
        : media.duration;
    if (_knownDurationSeconds > 0 && duration.inSeconds == 0) {
      duration = Duration(seconds: _knownDurationSeconds);
    }
    _onDurationChanged = onDurationChanged;
    _onPlayingChanged = onPlayingChanged;
    _onQualitySwitchingChanged = onQualitySwitchingChanged;
    _onTracksChanged = onTracksChanged;

    final streamUrl = apiClient.getStreamUrl(media.id);

    MediaTracks? loadedTracks;
    try {
      await Future.wait([
        apiClient.getMediaTracks(media.id).then((tracks) {
          loadedTracks = tracks;
        }),
        player.open(mk.Media(streamUrl), play: false),
      ]);
      mediaTracks = loadedTracks;
      if (inheritedPreferences != null) {
        _applyInheritedPreferences(inheritedPreferences);
      } else {
        _subtitlesExplicitlyOff = true;
        _selectedSubtitleLang = null;
        _selectedInternalSubId = null;
        if (mediaTracks != null && mediaTracks!.audio.isNotEmpty) {
          // Honor the file's default audio track on first open.
          final def = mediaTracks!.audio.indexWhere((a) => a.isDefault);
          _selectedAudioIndex = def >= 0 ? def : 0;
        }
      }
      _pendingPreferenceReapply = true;
    } catch (e) {
      debugPrint("Player: failed to load media tracks or open stream: $e");
      if (loadedTracks == null) {
        try {
          await player.open(mk.Media(streamUrl), play: false);
        } catch (openErr) {
          debugPrint("Player: failed to open stream: $openErr");
        }
      }
    }

    if (inheritedPreferences == null || inheritedPreferences.subtitlesOff) {
      try {
        player.setSubtitleTrack(mk.SubtitleTrack.no());
      } catch (_) {}
    }
  }

  Future<void> _applyDirectPlayPlayerProperties() async {
    final platform = player.platform as dynamic;
    await platform.setProperty('cache', 'yes');
    // ~4 min forward buffer: large enough to absorb any network jitter without
    // hoarding hundreds of MB of RAM (memory pressure on 8GB machines causes
    // periodic decode stalls — video freezes while audio keeps playing).
    await platform.setProperty('demuxer-max-bytes', '268435456');
    await platform.setProperty('demuxer-readahead-secs', '240');
    await platform.setProperty('hr-seek', 'yes');
    // Whitelisted hardware decoders only (VideoToolbox on macOS, D3D11 on
    // Windows, MediaCodec on Android). Plain 'auto' may pick flaky paths that
    // stall the video track while audio continues.
    // macOS 27 beta: VideoToolbox (hwdec=auto-safe) causes periodic video-only
    // freezes while audio continues. Force software decoding on macOS until the
    // OS is stable. Windows/Android keep auto-safe (D3D11/MediaCodec are fine).
    await platform.setProperty('hwdec', Platform.isMacOS ? 'no' : 'auto-safe');
    // Direct rendering (decoding straight into GPU-mapped buffers) is a known
    // source of periodic video freezes with the libmpv render API embedding
    // used by media_kit; the extra copy is negligible.
    await platform.setProperty('vd-lavc-dr', 'no');
    await platform.setProperty('sub-auto', 'no');
    await platform.setProperty('network-timeout', '60');
    // Transparent reconnection if the OS/router drops the long-lived HTTP
    // connection while the demuxer buffer is full (socket idle for minutes).
    await platform.setProperty(
        'stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    if (Platform.isMacOS) {
      // macOS rendering pipeline (mpv → OpenGL → CVPixelBuffer → Metal →
      // Flutter) can stall periodically, especially on macOS 27 beta. These
      // properties prevent the video output from blocking when the texture
      // bridge can't keep up — mpv drops frames instead of freezing.
      await platform.setProperty('framedrop', 'vo');
      await platform.setProperty('video-sync', 'display-desync');
      await platform.setProperty('cache-pause', 'no');
    }
  }

  void _scheduleDeferredSubtitleExtraction() {
    if (_autoExtractStarted || _disposed) return;
    if (!_hasPendingSubtitles()) return;

    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = Timer(_subtitleExtractDelay, () {
      if (_disposed) return;
      _ensureSubtitlesExtracted();
    });
  }

  void _notifyTracksChanged() {
    _onTracksChanged?.call();
    if (!_tracksStreamController.isClosed) {
      _tracksStreamController.add(null);
    }
  }

  bool _isSubtitleReady(String lang) {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    for (final s in subs) {
      if (s.lang == lang) return s.ready;
    }
    return false;
  }

  bool _hasPendingSubtitles() {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    return subs.any((s) => !s.ready);
  }

  Future<void> _refreshMediaTracks() async {
    if (_media == null || _apiClient == null) return;
    try {
      mediaTracks = await _apiClient!.getMediaTracks(_media!.id);
      _notifyTracksChanged();
    } catch (e) {
      debugPrint("SUB: failed to refresh tracks: $e");
    }
  }

  /// Refreshes the canonical track list and, when a subtitle language is already
  /// chosen, attaches it as soon as its .vtt becomes ready — no HLS reload.
  Future<void> _onSubtitlesUpdated({bool applyIfSelected = true}) async {
    await _refreshMediaTracks();
    if (applyIfSelected &&
        !_subtitlesExplicitlyOff &&
        _selectedSubtitleLang != null &&
        currentQuality != null &&
        _isSubtitleReady(_selectedSubtitleLang!)) {
      _applySubtitleSelection();
    }
    if (!_hasPendingSubtitles()) {
      _stopSubtitleWatch();
    }
  }

  void _startSubtitleWatch() {
    if (_subtitleWatchTimer != null) return;
    _subtitleWatchTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) {
        _stopSubtitleWatch();
        return;
      }
      _onSubtitlesUpdated();
    });
  }

  void _stopSubtitleWatch() {
    _subtitleWatchTimer?.cancel();
    _subtitleWatchTimer = null;
  }

  /// Triggers a one-shot, non-blocking background subtitle extraction when any
  /// text subtitle is still missing its .vtt. When tracks flip to ready the
  /// active selection is applied automatically in HLS — no session reload.
  void _ensureSubtitlesExtracted() {
    if (_autoExtractStarted) return;
    final api = _apiClient;
    final media = _media;
    if (api == null || media == null) return;
    if (!_hasPendingSubtitles()) return;

    _autoExtractStarted = true;
    _isExtractingSubtitles = true;
    _startSubtitleWatch();
    debugPrint("SUB: background extraction started for media ${media.id}");
    api.forceMediaSubtitleExtract(media.id, force: false).then((_) async {
      _isExtractingSubtitles = false;
      if (_disposed) return;
      await _onSubtitlesUpdated();
      debugPrint(
          "SUB: background extraction done, ${mediaTracks?.subtitles.length ?? 0} tracks");
    }).catchError((e) {
      _isExtractingSubtitles = false;
      debugPrint("SUB: background extraction failed: $e");
    });
  }

  // ==================== Heartbeat / progress ====================

  Future<void> _waitUntilSeekable() async {
    if (player.state.duration > Duration.zero) return;

    try {
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 8));
      return;
    } catch (_) {}

    try {
      if (!player.state.buffering) {
        await player.stream.buffering
            .firstWhere((b) => b)
            .timeout(const Duration(seconds: 3));
      }
      await player.stream.buffering
          .firstWhere((b) => !b)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }

  /// Starts playback, optionally resuming at an absolute position in the media.
  Future<void> startPlayback({
    required int mediaId,
    required ApiClient apiClient,
    int resumeAtSeconds = 0,
  }) async {
    if (resumeAtSeconds > 0 && currentQuality == null && _media != null) {
      // The media was already opened (paused) in init(). Start playing, wait
      // for the first buffering cycle to complete, then seek to the resume
      // position. The mpv `start` property approach is unreliable with
      // media_kit 1.2.6 because open() returns before mpv processes the
      // loadfile command, and the immediate `start=0` reset cancels the
      // resume offset before mpv applies it.
      await player.play();
      try {
        if (!player.state.buffering) {
          await player.stream.buffering
              .firstWhere((b) => b)
              .timeout(const Duration(seconds: 3));
        }
        await player.stream.buffering
            .firstWhere((b) => !b)
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
      if (!_disposed) {
        await player.seek(Duration(seconds: resumeAtSeconds));
        position = Duration(seconds: resumeAtSeconds);
      }
    } else {
      await player.play();
    }
    if (_pendingPreferenceReapply) {
      _pendingPreferenceReapply = false;
      _reapplySelectionsAfterLoad();
    }
    startHeartbeat(mediaId: mediaId, apiClient: apiClient);
    _setPlaying(player.state.playing);
    _scheduleDeferredSubtitleExtraction();
  }

  void _setPlaying(bool playing) {
    if (isPlaying == playing) return;
    isPlaying = playing;
    _onPlayingChanged?.call();
  }

  void togglePlayPause() {
    final next = !isPlaying;
    _setPlaying(next);
    if (next) {
      player.play();
    } else {
      player.pause();
    }
  }

  void startHeartbeat({required int mediaId, required ApiClient apiClient}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
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
    var durSeconds = duration.inSeconds;
    if (durSeconds <= 0 && _knownDurationSeconds > 0) {
      durSeconds = _knownDurationSeconds;
    }
    if (posSeconds <= 0) return;
    try {
      await apiClient.sendProgress(
        mediaId: mediaId,
        currentPositionSeconds: posSeconds,
        duration: durSeconds,
        isFinished: isFinished,
      );
    } catch (e) {
      debugPrint("Player: failed to sync progress: $e");
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
    var durSeconds = duration.inSeconds;
    if (durSeconds <= 0 && _knownDurationSeconds > 0) {
      durSeconds = _knownDurationSeconds;
    }
    if (posSeconds > 0) {
      var finalIsFinished = isFinished;
      if (!finalIsFinished && durSeconds > 0 && (posSeconds / durSeconds) * 100 >= 90.0) {
        finalIsFinished = true;
      }
      await _sendProgress(mediaId: mediaId, apiClient: apiClient, isFinished: finalIsFinished);
    }
  }

  // ==================== Quality switching ====================

  /// Switch transcoding quality (or start transcoding from Direct Play),
  /// resuming at the exact same second. Always shows the loading spinner.
  Future<void> switchToQuality(String quality) async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == quality) return;
    await _openHlsSession(quality: quality, startSeconds: position.inSeconds);
  }

  /// Reload the HLS session at a new absolute position (large seeks in HLS mode,
  /// where segments outside the sliding window no longer exist).
  Future<void> reloadHlsAtPosition(int newPositionSeconds) async {
    if (_media == null || _apiClient == null || currentQuality == null) return;
    await _openHlsSession(quality: currentQuality!, startSeconds: newPositionSeconds);
  }

  /// Core HLS (re)launch: ask the server for a fresh session, open its master
  /// playlist directly (mpv handles child playlists/segments), force the full
  /// duration and re-apply the audio/subtitle selection.
  Future<void> _openHlsSession({
    required String quality,
    required int startSeconds,
  }) async {
    if (_media == null || _apiClient == null) return;

    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    final mediaId = _media!.id;
    final oldSessionId = _hlsSessionId;

    try {
      final hls = await _apiClient!.startHlsSession(
        mediaId,
        quality,
        startSeconds: startSeconds,
        audioIndex: _selectedAudioIndex,
      );

      // Tear down the previous session only once the new one is ready.
      if (oldSessionId != null) {
        _apiClient!.destroyHlsSession(mediaId, oldSessionId);
      }

      _hlsSessionId = hls.sessionId;
      currentQuality = quality;
      _hlsStartOffset = startSeconds;

      await _applyHlsPlayerProperties();
      await player.open(mk.Media(hls.masterUrl), play: true);
      _forceDuration(hls.totalDuration);
      _reapplySelectionsAfterLoad();
      _hideLoadingAfterBuffer();

      // Kick off .vtt extraction in the background and poll until ready so a
      // language picked in Direct Play (or in the menu) attaches without reload.
      _ensureSubtitlesExtracted();
      if (_selectedSubtitleLang != null && !_isSubtitleReady(_selectedSubtitleLang!)) {
        _startSubtitleWatch();
      }
    } catch (e) {
      debugPrint("Player: failed to open HLS session: $e");
      isSwitchingQuality = false;
      _onQualitySwitchingChanged?.call();
    }
  }

  /// Switch back to Direct Play from HLS, resuming at the same second.
  Future<void> switchToDirectPlay() async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == null) return;

    final savedSeconds = position.inSeconds;
    isSwitchingQuality = true;
    _onQualitySwitchingChanged?.call();

    await _destroyHlsSession();

    currentQuality = null;
    _hlsStartOffset = 0;
    duration = Duration.zero;

    await _applyDirectPlayPlayerProperties();
    final streamUrl = _apiClient!.getStreamUrl(_media!.id);
    await player.open(mk.Media(streamUrl), play: true);

    // Wait for a full buffering cycle so the stream is connected and seekable.
    try {
      if (!player.state.buffering) {
        await player.stream.buffering
            .firstWhere((b) => b)
            .timeout(const Duration(seconds: 3));
      }
      await player.stream.buffering
          .firstWhere((b) => !b)
          .timeout(const Duration(seconds: 7));
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 1200));
    }

    if (savedSeconds > 0 && !_disposed) {
      await player.seek(Duration(seconds: savedSeconds));
      await Future.delayed(const Duration(milliseconds: 400));
    }

    _reapplySelectionsAfterLoad();

    isSwitchingQuality = false;
    _onQualitySwitchingChanged?.call();
  }

  /// Seek to an absolute position in the media (handles HLS stream offset).
  Future<void> seekToAbsoluteSeconds(int absoluteSeconds) async {
    final target = absoluteSeconds < 0 ? 0 : absoluteSeconds;
    if (currentQuality != null && _hlsStartOffset > 0) {
      await player.seek(Duration(seconds: target - _hlsStartOffset));
    } else {
      await player.seek(Duration(seconds: target));
    }
  }

  // ==================== Audio / subtitle selection ====================

  /// Select an audio track by canonical index.
  ///
  ///   - Direct Play: switch natively and instantly (all tracks are present).
  ///   - HLS: the stream only carries the single requested track to keep CPU
  ///     low, so we restart the session at the same second with the new track.
  Future<void> switchAudioTrack(int index) async {
    if (mediaTracks == null) return;
    if (index < 0 || index >= mediaTracks!.audio.length) return;
    if (index == _selectedAudioIndex) return;
    _selectedAudioIndex = index;

    if (currentQuality != null) {
      await reloadHlsAtPosition(position.inSeconds);
      return;
    }
    _applyAudioSelection();
  }

  /// Turn subtitles on (first available track) or off.
  Future<void> toggleSubtitles() async {
    if (!_subtitlesExplicitlyOff &&
        (_selectedSubtitleLang != null || _selectedInternalSubId != null)) {
      await setSubtitle(null);
      return;
    }

    if (currentQuality == null) {
      final tracks = player.state.tracks.subtitle;
      for (final track in tracks) {
        if (track.id == 'no' || track.id == 'auto') continue;
        selectInternalSubtitle(track);
        return;
      }
    }

    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    if (subs.isEmpty) return;

    final ready = subs.where((s) => s.ready).toList();
    final pick = ready.isNotEmpty ? ready.first : subs.first;
    await setSubtitle(pick.lang);
  }

  /// Select a subtitle by language code, or null to disable. Used by the HLS
  /// menu (external WebVTT). In Direct Play the embedded tracks are used instead
  /// via [selectInternalSubtitle], so this is the canonical/HLS path.
  ///
  /// If the .vtt is not ready yet, extraction is triggered and the track is
  /// attached automatically as soon as it becomes available — no HLS reload.
  Future<void> setSubtitle(String? lang) async {
    if (_media == null || _apiClient == null) return;
    _selectedSubtitleLang = lang;
    _selectedInternalSubId = null;
    _subtitlesExplicitlyOff = lang == null || lang.isEmpty;

    if (lang == null || lang.isEmpty) {
      _applySubtitleSelection();
      return;
    }

    if (currentQuality != null && !_isSubtitleReady(lang)) {
      _ensureSubtitlesExtracted();
      _startSubtitleWatch();
      return;
    }

    _applySubtitleSelection();
  }

  /// Direct Play: select one of the MKV's embedded subtitle tracks natively and
  /// remember it (id + normalized language) so the choice survives a reload and
  /// carries over to HLS without the user ever seeing the source change.
  void selectInternalSubtitle(mk.SubtitleTrack track) {
    final isOff = track.id == 'no';
    _selectedInternalSubId = isOff ? null : track.id;
    _selectedSubtitleLang = isOff ? null : _normalizeLang(track.language);
    _subtitlesExplicitlyOff = isOff;
    try {
      player.setSubtitleTrack(track);
    } catch (_) {}
  }

  /// Force subtitle extraction for the current media. Refreshes the track list
  /// and attaches the active language immediately when the .vtt is ready.
  Future<List<MediaSubtitleTrack>> forceExtractSubtitles() async {
    if (_media == null || _apiClient == null) {
      throw StateError('Player not initialized');
    }
    _autoExtractStarted = true;
    _isExtractingSubtitles = true;
    _startSubtitleWatch();
    try {
      final subs = await _apiClient!.forceMediaSubtitleExtract(_media!.id);
      await _onSubtitlesUpdated();
      return subs;
    } finally {
      _isExtractingSubtitles = false;
    }
  }

  List<mk.AudioTrack> _realAudioTracks() => player.state.tracks.audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  void _applyAudioSelection() {
    final real = _realAudioTracks();
    if (real.isEmpty) return;
    final i = _selectedAudioIndex.clamp(0, real.length - 1);
    try {
      player.setAudioTrack(real[i]);
    } catch (_) {}
  }

  /// Monotonic token guarding against out-of-order subtitle loads (the user
  /// switching language quickly, or a reload firing mid-fetch).
  int _subtitleRequestId = 0;

  void _applySubtitleSelection() {
    // Direct Play is served entirely by the MKV's embedded subtitles: we never
    // inject external WebVTT here, so the user never sees a switch between the
    // internal and external sources. The external .vtt only drives HLS, where
    // the original file is no longer streamed.
    if (currentQuality == null) {
      _applyInternalSubtitleSelection();
      return;
    }

    final lang = _selectedSubtitleLang;
    final reqId = ++_subtitleRequestId;

    // Always clear the current external subtitle first. mpv's `sub-add ... select`
    // does NOT reliably switch the active selection when another external track
    // is already loaded (the second language would never show). Going through
    // `no()` first forces a clean re-selection. This also handles "off".
    try {
      player.setSubtitleTrack(mk.SubtitleTrack.no());
      debugPrint("SUB: cleared current subtitle before applying selection");
    } catch (_) {}

    if (lang == null || lang.isEmpty) return;

    String? title;
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    for (final s in subs) {
      if (s.lang == lang) {
        title = s.displayName;
        break;
      }
    }

    // Download the WebVTT ourselves and inject it as in-memory data. Asking mpv
    // to fetch a URL works in Direct Play but is unreliable while it is pulling
    // an HLS stream — the external track silently never loads. The network round
    // trip also gives mpv time to process the `no()` above before we re-add.
    final inHls = currentQuality != null;
    final start = inHls ? _hlsStartOffset : 0;
    final mediaId = _media!.id;

    debugPrint("SUB: request #$reqId lang=$lang start=$start hls=$inHls");
    _apiClient!.fetchSubtitleContent(mediaId, lang, start: start).then((vtt) async {
      // Ignore stale responses (selection changed while we were fetching).
      if (_disposed || reqId != _subtitleRequestId) {
        debugPrint("SUB: #$reqId stale (current=$_subtitleRequestId), skipping");
        return;
      }
      final cueCount = '-->'.allMatches(vtt).length;
      if (cueCount == 0) {
        debugPrint("SUB: #$reqId lang=$lang has NO cues (${vtt.length} chars) — nothing to show");
        return;
      }
      debugPrint("SUB: #$reqId lang=$lang fetched ${vtt.length} chars, $cueCount cues");
      try {
        await player.setSubtitleTrack(
          mk.SubtitleTrack.data(vtt, title: title, language: lang),
        );
        // Read state only AFTER the command has actually run, plus a tick for
        // mpv's track-list event to propagate back.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_disposed) return;
        final subs = player.state.tracks.subtitle.map((t) => t.id).toList();
        debugPrint("SUB: #$reqId applied. mpv subtitle tracks: $subs, "
            "active=${player.state.track.subtitle.id}, "
            "visible=${player.state.subtitle}");
      } catch (e) {
        debugPrint("SUB: #$reqId failed to attach data: $e");
      }
    }).catchError((e) {
      debugPrint("SUB: #$reqId failed to fetch lang=$lang: $e");
    });
  }

  /// Direct Play: re-select the embedded subtitle that matches the user's choice
  /// after a reload (e.g. returning from HLS). Tries the exact mpv id first, then
  /// language matching, so the same subtitle stays on without a visible flip.
  void _applyInternalSubtitleSelection() {
    if (_subtitlesExplicitlyOff) {
      try {
        player.setSubtitleTrack(mk.SubtitleTrack.no());
      } catch (_) {}
      return;
    }

    if (_selectedInternalSubId == null && _selectedSubtitleLang == null) {
      try {
        player.setSubtitleTrack(mk.SubtitleTrack.no());
      } catch (_) {}
      return;
    }

    final tracks = player.state.tracks.subtitle;
    if (tracks.isEmpty) return;

    mk.SubtitleTrack? match;
    if (_selectedInternalSubId != null) {
      for (final t in tracks) {
        if (t.id == _selectedInternalSubId) {
          match = t;
          break;
        }
      }
    }
    if (match == null && _selectedSubtitleLang != null) {
      for (final t in tracks) {
        if (_normalizeLang(t.language) == _selectedSubtitleLang) {
          match = t;
          break;
        }
      }
    }
    try {
      player.setSubtitleTrack(match ?? mk.SubtitleTrack.no());
    } catch (_) {}
  }

  /// Normalize a subtitle language tag to a 2-letter code so embedded (MKV) and
  /// external (.vtt) tracks can be matched across a mode switch. Returns null
  /// for undefined / "off" tags.
  String? _normalizeLang(String? code) {
    if (code == null) return null;
    var c = code.trim().toLowerCase();
    if (c.isEmpty || c == 'und' || c == 'auto' || c == 'no') return null;
    const map = {
      'fra': 'fr', 'fre': 'fr', 'french': 'fr',
      'eng': 'en', 'english': 'en',
      'spa': 'es', 'esp': 'es', 'spanish': 'es',
      'ger': 'de', 'deu': 'de', 'german': 'de',
      'ita': 'it', 'italian': 'it',
      'por': 'pt', 'portuguese': 'pt',
      'jpn': 'ja', 'japanese': 'ja',
      'rus': 'ru', 'russian': 'ru',
      'chi': 'zh', 'zho': 'zh', 'chinese': 'zh',
      'ara': 'ar', 'arabic': 'ar',
      'nld': 'nl', 'dut': 'nl', 'dutch': 'nl',
      'kor': 'ko', 'korean': 'ko',
    };
    if (map.containsKey(c)) return map[c];
    if (c.length > 2) return c.substring(0, 2);
    return c;
  }

  /// Re-apply audio + subtitle selection once the freshly opened media has
  /// enumerated its tracks (with a safety fallback).
  void _reapplySelectionsAfterLoad() {
    _reapplySubscription?.cancel();
    var applied = false;

    void apply() {
      if (applied || _disposed) return;
      applied = true;
      _applyAudioSelection();
      _applySubtitleSelection();
      _reapplySubscription?.cancel();
      _reapplySubscription = null;
    }

    _reapplySubscription = player.stream.tracks.listen((t) {
      final hasAudio = t.audio.any((e) => e.id != 'auto' && e.id != 'no');
      if (hasAudio) apply();
    });
    Timer(const Duration(milliseconds: 1500), apply);
  }

  // ==================== HLS helpers ====================

  Future<void> _applyHlsPlayerProperties() async {
    try {
      final p = player.platform as dynamic;
      await p.setProperty('force-seekable', 'yes');
      await p.setProperty('cache', 'yes');
      await p.setProperty('demuxer-seekable-cache', 'yes');
      await p.setProperty('demuxer-max-bytes', '104857600');
      await p.setProperty('demuxer-readahead-secs', '60');
      // Same decode-path hardening as Direct Play — prevents video-only
      // freezes while audio keeps playing.
      await p.setProperty('hwdec', Platform.isMacOS ? 'no' : 'auto-safe');
      await p.setProperty('vd-lavc-dr', 'no');
      // HLS segments are short HTTP requests; reconnection is cheap insurance
      // against transient network blips between segment fetches.
      await p.setProperty(
          'stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
      if (Platform.isMacOS) {
        await p.setProperty('framedrop', 'vo');
        await p.setProperty('video-sync', 'display-desync');
        await p.setProperty('cache-pause', 'no');
      }
    } catch (_) {}
  }

  void _forceDuration(double totalDurationSeconds) {
    if (totalDurationSeconds <= 0) return;
    duration = Duration(seconds: totalDurationSeconds.round());
    try {
      (player.platform as dynamic).setProperty('length', totalDurationSeconds.toStringAsFixed(3));
    } catch (_) {}
    _onDurationChanged?.call();
  }

  /// Hide the spinner once buffering has started and then stopped (the stream
  /// is actually playing), with a safety timeout.
  void _hideLoadingAfterBuffer() {
    StreamSubscription? sub;
    var sawBuffering = false;
    sub = player.stream.buffering.listen((isBuffering) {
      if (isBuffering) {
        sawBuffering = true;
      } else if (sawBuffering) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
        sub?.cancel();
      }
    });
    Timer(const Duration(seconds: 15), () {
      sub?.cancel();
      if (isSwitchingQuality) {
        isSwitchingQuality = false;
        _onQualitySwitchingChanged?.call();
      }
    });
  }

  Future<void> _destroyHlsSession() async {
    if (_hlsSessionId == null || _media == null || _apiClient == null) return;
    await _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    _hlsSessionId = null;
  }

  // ==================== Teardown ====================

  void cancelStreams() {
    _disposed = true;
    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = null;
    _stopSubtitleWatch();
    _heartbeatTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _playingSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _reapplySubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription = null;
    _completedSubscription = null;
    _playingSubscription = null;
    _videoParamsSubscription = null;
    _reapplySubscription = null;
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
  }

  void dispose() {
    _disposed = true;
    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = null;
    _stopSubtitleWatch();
    _tracksStreamController.close();
    _heartbeatTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _reapplySubscription?.cancel();
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
    player.dispose();
  }
}
