import 'dart:async';
import 'package:flutter/material.dart';
import '../../../models/models.dart';
import '../../../utils/app_platform.dart';
import '../player_engine.dart';
import '../web/web_playback.dart';
import '../display_frame_rate.dart';
import '../hardware_decoding.dart';
import '../playback/playback_engine.dart';
import '../playback/playback_session.dart';
import '../playback_profile.dart';
import '../web_quality.dart';
import '../../../services/api_client.dart';
import '../../../services/playback_preferences_storage.dart';
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
  /// Le moteur de lecture, derrière son port.
  ///
  /// mpv sur macOS, Windows et le web ; ExoPlayer sur Android. Tout ce qui suit
  /// dans ce fichier — reprise, sessions HLS, heartbeat, modèle de pistes,
  /// préférences, bascule de qualité — s'écrit une seule fois pour les deux.
  late final PlaybackSession session;

  bool isInitialized = false;
  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isDraggingSlider = false;
  double dragValue = 0.0;

  /// True while switching quality / rebuilding the HLS session (drives the UI spinner).
  bool isSwitchingQuality = false;

  /// True while mpv is waiting for the demuxer cache to refill (network underrun).
  bool isBuffering = false;

  /// True once this session has decoded a frame of *this* media.
  ///
  /// The libmpv instance and its texture come from [PlayerEnginePool] and are
  /// reused across playbacks, so between `open()` and the first decoded frame
  /// the texture still holds the last frame of whatever played before. Opening
  /// a second title therefore flashed the previous one. Callers cover the video
  /// until this turns true; it is the only signal that the picture on screen
  /// belongs to the media that was asked for.
  bool hasFirstFrame = false;

  /// The decoder has read this file's dimensions — it knows what it is about to
  /// draw, but has not necessarily drawn it yet.
  ///
  /// Which signal carries that differs by platform; see where it is subscribed.
  bool _videoParamsReady = false;

  /// The playback clock has ticked at least once while playing, which mpv only
  /// does once it is presenting frames.
  bool _clockRunning = false;

  /// [hasFirstFrame] needs both, and one frame more.
  ///
  /// Neither signal alone is late enough. `videoParams` fires on load, well
  /// before anything is drawn. The clock can tick on the very frame the new
  /// picture reaches the texture. Since the engine texture is pooled and still
  /// holds the previous title, lifting the cover one frame early is exactly the
  /// flash this guards against — so the last hop waits for the next frame,
  /// which costs about 16ms and cannot be seen.
  void _maybeMarkFirstFrame() {
    if (hasFirstFrame || !_videoParamsReady || !_clockRunning) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || hasFirstFrame) return;
      hasFirstFrame = true;
      _onFirstFrame?.call();
      unawaited(_onPictureLive());
    });
  }

  /// Runs once the picture is actually on screen.
  ///
  /// Two things need the decoder to have committed to a file, and neither can
  /// be answered before it has: which rate the panel should run at, and what
  /// the engine actually chose to decode with.
  Future<void> _onPictureLive() async {
    if (AppPlatform.isWeb || _disposed) return;

    final info = await session.readDiagnostics();
    final fps = info.containerFps ?? 0;
    if (fps > 0) await DisplayFrameRate.matchTo(fps);

    final params = session.videoParams;
    // The one line that says what is really happening. The decoder reported
    // here is the engine's own answer, not what it was asked for: one that
    // failed to start falls back silently, and the setting tells you nothing
    // about whether a frame ever reached the GPU that way.
    debugPrint('Playback: ${params.width}x${params.height} '
        '${info.videoCodec} @ ${fps.toStringAsFixed(3)}fps '
        '· hwdec=${info.hardwareDecoder} '
        '(asked ${HardwareDecoding.describe()}) · '
        'buffers=${PlaybackProfiles.current.label}'
        '${DisplayFrameRate.requested != null ? ' · display=${DisplayFrameRate.requested}Hz' : ''}');

    // Read, never written. Logged because "the sound is not right" is otherwise
    // unanswerable: this line says whether the device received six channels and
    // folded them itself — the case the dialogue-forward mix levels apply to —
    // or was handed a stereo pair the server had already folded for it.
    debugPrint('Audio: ${info.sourceChannels}ch source → '
        '${info.outputChannels}ch out · ${info.audioCodec}');

    // The engine's own chance to correct what it just observed of itself.
    await session.onPictureLive();
  }

  /// Dropped-frame counters, logged on the way out.
  ///
  /// "It stutters" is otherwise a matter of opinion; these two numbers are not.
  Future<void> _logDropCounters() async {
    if (AppPlatform.isWeb) return;
    final info = await session.readDiagnostics();
    final display = info.droppedByDisplay ?? 0;
    final decoder = info.droppedByDecoder ?? 0;
    if (display == 0 && decoder == 0) return;
    debugPrint('Playback: dropped frames — display=$display decoder=$decoder');
  }

  /// In HLS mode the stream timeline resets to 0 at this offset (seconds) into
  /// the original media. Used to display the absolute position and to compute
  /// seek targets. 0 in Direct Play.
  int _hlsStartOffset = 0;
  int get hlsStartOffset => _hlsStartOffset;

  /// Current transcoding quality. null = Direct Play.
  String? currentQuality;
  String? _hlsSessionId;

  /// Source audio tracks the current HLS session publishes as renditions, in
  /// player enumeration order. Empty in Direct Play, where the player sees the
  /// file's own tracks directly.
  List<int> _hlsAudioMap = const [];

  /// Bitmap subtitle stream (0:s:N) currently painted into the transcoded video,
  /// or -1. Carried across quality switches and seek reloads so the choice is not
  /// silently lost, since every one of those rebuilds the session.
  int _hlsBurnedSubTypedIndex = -1;

  /// True while one HLS session is being replaced by another. Position and
  /// duration events are ignored during that window: they may still describe
  /// the outgoing stream while the offsets they are combined with already
  /// describe the incoming one.
  bool _hlsSwapInFlight = false;

  Media? _media;
  ApiClient? _apiClient;
  int _knownDurationSeconds = 0;
  VoidCallback? _onDurationChanged;
  VoidCallback? _onPositionChanged;
  VoidCallback? _onQualitySwitchingChanged;
  VoidCallback? _onBufferingChanged;
  VoidCallback? _onFirstFrame;
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

  /// Language tag of the audio track currently selected, when the canonical
  /// list knows it. Carried to the next episode so mpv can pick the equivalent
  /// track at load time.
  String? get _selectedAudioLang {
    final audio = mediaTracks?.audio ?? const <MediaAudioTrack>[];
    if (_selectedAudioIndex < 0 || _selectedAudioIndex >= audio.length) {
      return null;
    }
    return PlaybackPreferencesStorage.normalizeLangCode(
        audio[_selectedAudioIndex].language);
  }

  PlayerPlaybackPreferences exportPreferences() {
    if (_subtitlesExplicitlyOff) {
      return PlayerPlaybackPreferences(
        audioIndex: _selectedAudioIndex,
        audioLang: _selectedAudioLang,
        subtitlesOff: true,
      );
    }

    final track = session.currentSubtitleTrack;
    final subsActive = track != null &&
        track.id != 'no' &&
        track.id != 'auto' &&
        track.id.isNotEmpty;

    if (!subsActive) {
      return PlayerPlaybackPreferences(
        audioIndex: _selectedAudioIndex,
        audioLang: _selectedAudioLang,
        subtitlesOff: true,
      );
    }

    return PlayerPlaybackPreferences(
      audioIndex: _selectedAudioIndex,
      audioLang: _selectedAudioLang,
      subtitleLang: _selectedSubtitleLang ?? _canonicalLangForEmbedded(track),
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
      _selectedSubtitleLang = _resolveCarriedSubtitleLang(prefs.subtitleLang);
      // The mpv id only means anything within the media it came from.
      _selectedInternalSubId =
          _selectedSubtitleLang == prefs.subtitleLang ? prefs.internalSubId : null;
    }
  }

  /// Re-resolve a subtitle key carried over from another media (auto-advance to
  /// the next episode).
  ///
  /// Keys are assigned in container order — `fr`, then `fr2` for a second French
  /// track — so the same key can mean the full track in one episode and the
  /// forced one in the next, depending on how each file was muxed. A forced
  /// track only subtitles foreign dialogue, so inheriting it as "French" looks
  /// exactly like subtitles being broken. Prefer a full track of the same base
  /// language whenever the episode has one.
  String? _resolveCarriedSubtitleLang(String? lang) {
    if (lang == null || lang.isEmpty) return lang;
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    if (subs.isEmpty) return lang;

    final base = lang.replaceAll(RegExp(r'\d+$'), '');
    MediaSubtitleTrack? exact;
    MediaSubtitleTrack? fullSameLanguage;
    for (final s in subs) {
      if (s.lang == lang) exact = s;
      if (s.lang.replaceAll(RegExp(r'\d+$'), '') == base &&
          !s.forced &&
          fullSameLanguage == null) {
        fullSameLanguage = s;
      }
    }

    if (exact != null && !exact.forced) return exact.lang;
    if (fullSameLanguage != null) return fullSameLanguage.lang;
    return lang;
  }

  Timer? _heartbeatTimer;
  Timer? _deferredSubtitleExtractTimer;

  /// Delay subtitle extraction so FFmpeg on the server does not compete with
  /// the HTTP stream for disk I/O during the first minutes of Direct Play.
  /// Delay before kicking off background subtitle extraction in Direct Play.
  ///
  /// Subtitles are no longer extracted at scan time, so this is the only thing
  /// that produces them — it can't wait long. It still waits out the initial
  /// demuxer burst (mpv prefetches ~240s up front) so the extraction's own
  /// sequential read doesn't fight the buffer that is filling right now.
  static const _subtitleExtractDelay = Duration(seconds: 20);
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _videoParamsSubscription;
  StreamSubscription? _bufferingSubscription;
  StreamSubscription? _reapplySubscription;
  bool _disposed = false;

  /// Aspect ratio of the current video (width / height).
  double videoAspectRatio = 16 / 9;

  /// Absolute second the Direct Play stream was handed to mpv at, or -1 when it
  /// was opened from the beginning. Set when [init] resolves the resume point in
  /// time to pass it to `Media.start`, which lets mpv open the HTTP stream
  /// directly at the right byte offset instead of playing from 0 and seeking.
  int _openedAtSeconds = -1;

  /// Resume point handed over by the screen, usually still in flight.
  ///
  /// Held onto because the web needs it later than anything else does: see
  /// [_startWebTranscode], which is the only place it can be applied there.
  Future<int>? _resumePositionFuture;

  /// Milestones of the current start-up, printed once playback is rolling.
  ///
  /// "It takes a while to start" is otherwise unattributable: the wait is split
  /// between the resume lookup, mpv opening the stream, the first frame being
  /// decoded and the first frame being painted, and only the breakdown says
  /// which one to attack.
  final Stopwatch _startupWatch = Stopwatch();
  final List<String> _startupMarks = [];
  bool _startupReported = false;

  /// Records the first occurrence of [label]; later ones are ignored, so a
  /// milestone driven by a stream (the first decoded frame) can be marked from
  /// inside a listener that fires many times.
  void _mark(String label) {
    if (!_startupWatch.isRunning || _startupReported) return;
    if (_startupMarks.any((m) => m.startsWith('$label='))) return;
    _startupMarks.add('$label=${_startupWatch.elapsedMilliseconds}ms');
  }

  void _reportStartup() {
    if (_startupReported || !_startupWatch.isRunning) return;
    _startupReported = true;
    _mark('playing');
    _startupWatch.stop();
    debugPrint('PLAYER STARTUP: ${_startupMarks.join(' ')}');
  }

  /// The pooled libmpv instance this controller drives. Held so it can be given
  /// back on dispose instead of destroyed.
  late final PlayerEngine _engine;

  PlayerController() {
    _engine = PlayerEnginePool.acquire();
    session = createPlaybackSession(_engine);
  }

  Future<void> init({
    required Media media,
    required ApiClient apiClient,
    required VoidCallback onCompleted,
    required VoidCallback onPositionChanged,
    required VoidCallback onDurationChanged,
    VoidCallback? onPlayingChanged,
    VoidCallback? onQualitySwitchingChanged,
    VoidCallback? onBufferingChanged,
    VoidCallback? onFirstFrame,
    VoidCallback? onTracksChanged,
    PlayerPlaybackPreferences? inheritedPreferences,
    int knownDurationSeconds = 0,
    Future<int>? resumePositionFuture,
  }) async {
    _startupWatch.start();
    // A pooled engine may still be unloading the last film. Opening on top of
    // that is how a playback ends up behind a spinner that never resolves.
    await _engine.settle();
    _mark('engine');
    _resumePositionFuture = resumePositionFuture;
    // Must run before media_kit injects hls.js: the bridge intercepts the
    // assignment of `window.Hls` so it can reclaim abandoned instances later.
    WebPlayback.install();

    try {
      await session.applyDirectPlayTuning(PlaybackProfiles.current);
    } catch (e) {
      debugPrint("Player: failed to apply native MPV properties: $e");
    }

    _positionSubscription = session.positions.listen((pos) {
      if (_disposed) return;
      // A session swap retires one stream and starts another. Until the new one
      // is fully wired, mpv can still emit positions belonging to the old
      // stream, and combining those with the new start offset yields an
      // absolute position that belongs to neither — large enough, on a big
      // seek, to exceed the media duration and blow up the progress bar.
      if (_hlsSwapInFlight) return;
      position = (currentQuality != null && _hlsStartOffset > 0)
          ? pos + Duration(seconds: _hlsStartOffset)
          : pos;
      // The clock advancing is the first moment the user is genuinely watching.
      if (isPlaying) {
        _reportStartup();
        _clockRunning = true;
        _maybeMarkFirstFrame();
      }
      onPositionChanged();
    });

    _playingSubscription = session.playingChanges.listen((playing) {
      if (_disposed) return;
      _setPlaying(playing);
    });

    _bufferingSubscription = session.bufferingChanges.listen((buffering) {
      if (_disposed) return;
      _setBuffering(buffering);
    });
    isBuffering = session.isBuffering;

    isPlaying = session.isPlaying;

    _durationSubscription = session.durations.listen((dur) {
      if (_disposed) return;
      // While transcoding we force the full media duration (MPV's reported
      // duration only covers the segments produced so far). During a swap
      // currentQuality may momentarily still read as Direct Play, so the swap
      // guard has to stand in for it — otherwise the growing HLS duration
      // overwrites the real one and every later position looks out of range.
      if (_hlsSwapInFlight || currentQuality != null) return;
      duration = dur;
      onDurationChanged();
    });

    _completedSubscription = session.completions.listen((_) {
      if (_disposed) return;
      onCompleted();
    });

    // Le moteur dit les dimensions à sa façon — `videoParams` pour mpv, la
    // taille intrinsèque de l'élément `<video>` sur le web, où mpv n'existe
    // pas. La différence est descendue dans la session : c'en est une entre
    // moteurs, pas entre écrans.
    _videoParamsSubscription = session.videoParamChanges.listen((params) {
      if (_disposed) return;
      final aspect = params.aspect;
      if (aspect == null || aspect <= 0) return;
      _mark('firstFrame');
      videoAspectRatio = aspect;
      _videoParamsReady = true;
      _maybeMarkFirstFrame();
    });

    _media = media;
    _apiClient = apiClient;
    _knownDurationSeconds =
        knownDurationSeconds > 0 ? knownDurationSeconds : media.duration;
    if (_knownDurationSeconds > 0 && duration.inSeconds == 0) {
      duration = Duration(seconds: _knownDurationSeconds);
    }
    _onDurationChanged = onDurationChanged;
    _onPositionChanged = onPositionChanged;
    _onPlayingChanged = onPlayingChanged;
    _onQualitySwitchingChanged = onQualitySwitchingChanged;
    _onBufferingChanged = onBufferingChanged;
    _onFirstFrame = onFirstFrame;
    _onTracksChanged = onTracksChanged;

    final streamUrl = apiClient.getStreamUrl(media.id);

    if (inheritedPreferences != null) {
      _applyInheritedPreferences(inheritedPreferences);
    } else {
      _subtitlesExplicitlyOff = true;
      _selectedSubtitleLang = null;
      _selectedInternalSubId = null;
    }

    // Direct Play is a native-only path. A browser cannot open the containers
    // and audio codecs a private library is actually made of, and the failure is
    // silent — picture, no sound, no message. Rather than open the file and back
    // out of it a moment later, the web waits for the track list and starts
    // straight in HLS, at the source's own resolution.
    if (!AppPlatform.isWeb) {
      // Which audio track to load with. The episode being carried over from
      // knows best; otherwise it is the user's standing preference, which lives
      // on this machine and costs nothing to read.
      var preferredAudioLang = inheritedPreferences?.audioLang;
      if (preferredAudioLang == null) {
        try {
          preferredAudioLang =
              await PlaybackPreferencesStorage().loadDefaultAudioLang();
        } catch (_) {
          preferredAudioLang = null;
        }
      }
      await _applyPreferredAudioLanguage(preferredAudioLang);

      _mark('prepared');
      // Resolve the resume point BEFORE opening, so mpv can be handed the offset
      // as part of the load itself. Playing from 0 and seeking afterwards meant
      // connecting, probing and buffering at the head of the file, then throwing
      // all of it away for a second connection at the real position — the whole
      // start-up cost paid twice, plus an audible blip from the first seconds.
      //
      // The lookup is already in flight (it starts before init), so this
      // normally costs nothing. If the server is slow to answer, give up on the
      // fast path rather than hold the picture hostage: -1 falls back to the
      // legacy open-then-seek in [startPlayback].
      var startAt = -1;
      if (resumePositionFuture != null) {
        try {
          startAt = await resumePositionFuture
              .timeout(const Duration(milliseconds: 1500));
        } catch (_) {
          startAt = -1;
        }
      } else {
        startAt = 0;
      }
      _mark('resume');

      try {
        await session.open(
          streamUrl,
          start: startAt > 0 ? Duration(seconds: startAt) : null,
          play: false,
        );
        if (startAt >= 0) {
          _openedAtSeconds = startAt;
          if (startAt > 0) position = Duration(seconds: startAt);
        }
      } catch (e) {
        debugPrint("Player: failed to open stream: $e");
      }
      _mark('opened');
    }

    unawaited(_loadMediaTracksAndPreferences(
      apiClient: apiClient,
      mediaId: media.id,
      inheritedPreferences: inheritedPreferences,
    ));

    if (inheritedPreferences == null || inheritedPreferences.subtitlesOff) {
      try {
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {}
    }
  }

  Future<void> _loadMediaTracksAndPreferences({
    required ApiClient apiClient,
    required int mediaId,
    required PlayerPlaybackPreferences? inheritedPreferences,
  }) async {
    try {
      final tracks = await apiClient.getMediaTracks(mediaId);
      if (_disposed) return;

      mediaTracks = tracks;

      // The track list is what carries the source resolution, so this is the
      // first moment the web can pick a quality. Nothing is playing yet on that
      // platform — init deliberately opened nothing.
      if (await _startWebTranscode()) return;

      if (inheritedPreferences != null) {
        _applyInheritedPreferences(inheritedPreferences);
      } else if (tracks.audio.isNotEmpty) {
        final defaultLang =
            await PlaybackPreferencesStorage().loadDefaultAudioLang();
        if (_disposed) return;
        _selectedAudioIndex = PlaybackPreferencesStorage.pickAudioIndex(
          tracks.audio,
          defaultLang,
        );
      }

      _pendingPreferenceReapply = true;
      _notifyTracksChanged();
      if (session.isPlaying) {
        _pendingPreferenceReapply = false;
        _reapplySelectionsAfterLoad();
        _scheduleDeferredSubtitleExtraction();
      }
    } catch (e) {
      debugPrint("Player: failed to load media tracks: $e");
    }
  }

  /// The second a web session should begin at, or 0.
  ///
  /// Bounded the same way the native path bounds it: a slow /progress response
  /// must not hold the picture hostage, and starting from the beginning is a far
  /// better failure than not starting.
  Future<int> _resolveWebResumeSeconds() async {
    final future = _resumePositionFuture;
    if (future == null) return 0;
    try {
      final seconds =
          await future.timeout(const Duration(milliseconds: 1500));
      return seconds > 0 ? seconds : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Starts playback on the web, which is always a transcoding session.
  ///
  /// Returns true when a session was started, so the caller stops configuring a
  /// player that is about to be handed a different source.
  Future<bool> _startWebTranscode() async {
    if (!AppPlatform.isWeb) return false;
    if (currentQuality != null) return false; // already running
    final tracks = mediaTracks;
    if (tracks == null) return false;

    final height = tracks.video?.height ?? 0;
    final surface = _surfacePixelHeight();
    final quality = webQualityFor(
      sourceHeight: height,
      viewportHeight: surface,
      sourceCodec: tracks.video?.codec ?? '',
    );
    // The resume point has to be part of the session rather than a seek applied
    // to it afterwards: the server transcodes from `?start=N` onwards, and the
    // rest of the film does not exist yet to seek into.
    //
    // This is also the only place it can be applied on the web. Every other
    // platform folds it into the open() that init() performs; a browser cannot
    // open anything until the track list has said which resolution to ask for,
    // and by then startPlayback has already run and found no session to
    // position. It used to depend on which of those two finished first — the
    // track list normally won, and the resume point was simply dropped.
    final startSeconds = await _resolveWebResumeSeconds();
    debugPrint("Player: web session — source ${height}px, surface ${surface}px, "
        "asking $quality from ${startSeconds}s (video=${tracks.video?.codec})");
    await switchToQuality(quality, startSeconds: startSeconds);
    return true;
  }

  /// Height in real pixels of the surface the video will be painted on.
  ///
  /// The player screen fills the window, so the window is the surface. Physical
  /// rather than logical pixels is what matters here: a 1440-logical-pixel window
  /// on a 2× display really does have 2880 rows to fill, and asking for 720p
  /// there would be visibly soft.
  ///
  /// 0 on anything unexpected, which [webQualityFor] reads as "apply no ceiling".
  int _surfacePixelHeight() {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return 0;
      return views.first.physicalSize.height.round();
    } catch (_) {
      return 0;
    }
  }

  /// Tells mpv which audio language to select when it loads the next file.
  ///
  /// Without this, the track list has to come back from the server before the
  /// choice can be made, so playback starts on whatever the container marked as
  /// default and switches a second later — and switching audio mid-playback
  /// makes mpv refill the demuxer for the new stream, which is audible.
  ///
  /// [code] is a normalized two-letter code, or null to let the file decide.
  /// Passing null must still write the property: on a reused engine, silence
  /// here would mean inheriting the previous media's preference.
  Future<void> _applyPreferredAudioLanguage(String? code) async {
    await session.setPreferredAudioLanguages(_alangPriorities(code));
  }

  /// Expands a two-letter code into the tags real files actually carry.
  ///
  /// A Matroska track is usually tagged with an ISO 639-2 code (`fre`, `ger`)
  /// and sometimes with a plain English name, none of which match the two-letter
  /// form on their own. Every spelling is offered at once, most likely first,
  /// rather than guessed at.
  static List<String> _alangPriorities(String? code) {
    if (code == null || code.isEmpty) return const [];
    const alternates = {
      'fr': ['fre', 'fra', 'french'],
      'en': ['eng', 'english'],
      'es': ['spa', 'esp', 'spanish'],
      'de': ['ger', 'deu', 'german'],
      'it': ['ita', 'italian'],
      'pt': ['por', 'portuguese'],
      'ja': ['jpn', 'japanese'],
      'ru': ['rus', 'russian'],
      'zh': ['chi', 'zho', 'chinese'],
      'ar': ['ara', 'arabic'],
      'nl': ['nld', 'dut', 'dutch'],
      'ko': ['kor', 'korean'],
    };
    return [code, ...?alternates[code]];
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

  /// Canonical track for a language key, or null when the media has no such key.
  MediaSubtitleTrack? _trackForLang(String lang) {
    for (final s in mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[]) {
      if (s.lang == lang) return s;
    }
    return null;
  }

  bool _isSubtitleReady(String lang) {
    final track = _trackForLang(lang);
    if (track == null) return false;
    // Bitmap tracks are never extracted — they are burned in on demand — so they
    // are usable the moment the media is known.
    if (track.image) return true;
    return track.ready;
  }

  bool _hasPendingSubtitles() {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    // A partial track still has work outstanding: the server is completing it.
    return subs.any((s) => !s.ready || s.partial);
  }

  /// True when [lang] is currently served from a head-only extraction. The cues
  /// stop partway through the media, so the track must be re-attached once the
  /// server finishes the complete pass.
  bool _isSubtitlePartial(String lang) {
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    for (final s in subs) {
      if (s.lang == lang) return s.partial;
    }
    return false;
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

  /// Signature of the external subtitle currently attached in HLS mode. The poll
  /// loop re-attaches only when this changes — first availability, or a
  /// head-only track being replaced by the complete one — instead of re-fetching
  /// and flickering the track on every tick.
  String? _attachedSubtitleSignature;

  String _subtitleSignature(String lang) =>
      '$lang|${_isSubtitlePartial(lang) ? 'head' : 'full'}|$_hlsStartOffset';

  /// Refreshes the canonical track list and, when a subtitle language is already
  /// chosen, attaches it as soon as its .vtt becomes ready — no HLS reload.
  Future<void> _onSubtitlesUpdated({bool applyIfSelected = true}) async {
    await _refreshMediaTracks();
    if (applyIfSelected &&
        !_subtitlesExplicitlyOff &&
        _selectedSubtitleLang != null &&
        currentQuality != null &&
        _isSubtitleReady(_selectedSubtitleLang!)) {
      final signature = _subtitleSignature(_selectedSubtitleLang!);
      if (signature != _attachedSubtitleSignature) {
        _applySubtitleSelection();
      }
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
    if (session.duration > Duration.zero) return;

    try {
      await session.durations
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 8));
      return;
    } catch (_) {}

    try {
      if (!session.isBuffering) {
        await session.bufferingChanges
            .firstWhere((b) => b)
            .timeout(const Duration(seconds: 3));
      }
      await session.bufferingChanges
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
    if (AppPlatform.isWeb) {
      // On the web the resume point is part of the session: the server was asked
      // to start transcoding at that second, so there is nothing to seek to —
      // and a seek would land outside the window it is producing anyway. When
      // the session is not up yet (it waits on the track list, which normally
      // arrives after this runs), _startWebTranscode is what applies the offset,
      // and it opens with play:true.
      await session.play();
    } else if (_openedAtSeconds == resumeAtSeconds && currentQuality == null) {
      // Already positioned: init() opened the stream at this exact second via
      // `Media.start`, which media_kit applies inside mpv's `on_load` hook —
      // i.e. before the file is loaded, so the offset is part of the load
      // instead of a seek that undoes it. Nothing left to do but play.
      await session.play();
    } else if (resumeAtSeconds > 0 && currentQuality == null && _media != null) {
      // Fallback when the resume point arrived too late to be part of the open
      // (slow /progress response). Start playing, wait for the first buffering
      // cycle to complete, then seek. Setting the mpv `start` property by hand
      // at this stage does not work with media_kit 1.2.6: open() returns before
      // mpv processes the loadfile command, and the immediate `start=0` reset
      // cancels the resume offset before mpv applies it.
      await session.play();
      await _waitUntilSeekable();
      if (!_disposed) {
        await session.seek(Duration(seconds: resumeAtSeconds));
        position = Duration(seconds: resumeAtSeconds);
      }
    } else {
      await session.play();
    }
    _mark('play');
    if (_pendingPreferenceReapply) {
      _pendingPreferenceReapply = false;
      _reapplySelectionsAfterLoad();
    }
    startHeartbeat(mediaId: mediaId, apiClient: apiClient);
    _setPlaying(session.isPlaying);
    _scheduleDeferredSubtitleExtraction();
  }

  void _setPlaying(bool playing) {
    if (isPlaying == playing) return;
    isPlaying = playing;
    _onPlayingChanged?.call();
  }

  void _setBuffering(bool buffering) {
    if (isBuffering == buffering) return;
    isBuffering = buffering;
    _onBufferingChanged?.call();
  }

  void togglePlayPause() {
    final next = !isPlaying;
    _setPlaying(next);
    if (next) {
      session.play();
    } else {
      session.pause();
    }
  }

  void startHeartbeat({required int mediaId, required ApiClient apiClient}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (session.isPlaying) {
        _sendProgress(
            mediaId: mediaId, apiClient: apiClient, isFinished: false);
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
      if (!finalIsFinished &&
          durSeconds > 0 &&
          (posSeconds / durSeconds) * 100 >= 90.0) {
        finalIsFinished = true;
      }
      await _sendProgress(
          mediaId: mediaId, apiClient: apiClient, isFinished: finalIsFinished);
    }
  }

  // ==================== Quality switching ====================

  /// Switch transcoding quality (or start transcoding from Direct Play),
  /// resuming at the exact same second. Always shows the loading spinner.
  ///
  /// [startSeconds] overrides that: the first web session of a media has no
  /// current second to preserve, it has a resume point to honour.
  Future<void> switchToQuality(String quality, {int? startSeconds}) async {
    if (_media == null || _apiClient == null) return;
    if (currentQuality == quality) return;

    if (currentQuality == null) {
      // Leaving Direct Play: a bitmap track the user picked there was being
      // rendered natively by mpv from the original file. That file is no longer
      // streamed once we transcode, so the choice only survives as a burn-in.
      _hlsBurnedSubTypedIndex =
          _subtitlesExplicitlyOff ? -1 : _burnIndexFor(_selectedSubtitleLang);
    }
    await _openHlsSession(
      quality: quality,
      startSeconds: startSeconds ?? position.inSeconds,
    );
  }

  /// Reload the HLS session at a new absolute position (large seeks in HLS mode,
  /// where segments outside the sliding window no longer exist).
  Future<void> reloadHlsAtPosition(int newPositionSeconds) async {
    if (_media == null || _apiClient == null || currentQuality == null) return;
    await _openHlsSession(
        quality: currentQuality!, startSeconds: newPositionSeconds);
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
    _hlsSwapInFlight = true;
    // Move the reported position to the target straight away. The rebuild takes
    // a few seconds, during which the swap guard (rightly) suppresses mpv's
    // position events — so without this the timeline would keep showing where
    // playback was BEFORE the seek, and the user cannot see what they clicked
    // until the video finally starts.
    position = Duration(seconds: startSeconds);
    _onPositionChanged?.call();
    _onQualitySwitchingChanged?.call();

    final mediaId = _media!.id;
    final oldSessionId = _hlsSessionId;

    try {
      final hls = await _apiClient!.startHlsSession(
        mediaId,
        quality,
        startSeconds: startSeconds,
        audioIndex: _selectedAudioIndex,
        burnSubtitleIndex: _hlsBurnedSubTypedIndex,
      );

      // Tear down the previous session only once the new one is ready.
      if (oldSessionId != null) {
        _apiClient!.destroyHlsSession(mediaId, oldSessionId);
      }

      await session.applyStreamingTuning(PlaybackProfiles.current);
      // The session publishes exactly the renditions the server was asked for,
      // and the selection among them is made by index through _hlsAudioMap. A
      // language preference left over from Direct Play would only give mpv a
      // second, disagreeing opinion about which one to play.
      await _applyPreferredAudioLanguage(null);
      // No longer a Direct Play stream opened at a known second.
      _openedAtSeconds = -1;
      await session.open(hls.masterUrl, play: true);
      // Two defects to undo on web. media_kit trusts `canPlayType` to decide
      // whether the browser speaks HLS — Chromium says "maybe" and cannot — so
      // hls.js has to be put back in charge. And it builds a fresh hls.js per
      // open() without ever destroying the last, so abandoned instances pile up
      // on the same <video>, each still running its loaders.
      WebPlayback.adoptHlsSession(hls.masterUrl);

      // _hlsStartOffset feeds directly into the position listener
      // (`pos + Duration(seconds: _hlsStartOffset)`). Setting it BEFORE
      // player.open() resolves left a window where a straggler position event
      // from the OLD stream (still in flight from mpv/media_kit's async
      // native side) got combined with the NEW target offset — producing an
      // absolute position that belongs to neither stream. On a big seek this
      // is not a one-frame flicker: it can read as "landed minutes away from
      // where I clicked". Every field the position/seek math depends on is
      // assigned only once we know player.open() has actually taken effect.
      _hlsSessionId = hls.sessionId;
      currentQuality = quality;
      _hlsStartOffset = startSeconds;
      _hlsAudioMap = hls.audioMap;
      // Trust the server: a track it could not burn in comes back as -1.
      _hlsBurnedSubTypedIndex = hls.burnedSubtitle;

      // Duration first, then reopen the gate: position events resume against a
      // coherent (offset, duration) pair rather than a half-updated one.
      _forceDuration(hls.totalDuration);
      position = Duration(seconds: startSeconds);
      _hlsSwapInFlight = false;
      _onPositionChanged?.call();

      _reapplySelectionsAfterLoad();
      _hideLoadingAfterBuffer();

      // Kick off .vtt extraction in the background and poll until ready so a
      // language picked in Direct Play (or in the menu) attaches without reload.
      _ensureSubtitlesExtracted();
      if (_selectedSubtitleLang != null &&
          !_isSubtitleReady(_selectedSubtitleLang!)) {
        _startSubtitleWatch();
      }
    } catch (e) {
      debugPrint("Player: failed to open HLS session: $e");
      isSwitchingQuality = false;
      // Must reopen even on failure: leaving the gate shut would freeze the
      // reported position for the rest of the session.
      _hlsSwapInFlight = false;
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
    _hlsAudioMap = const [];
    // Direct Play renders bitmap subtitles natively; nothing is burned in.
    _hlsBurnedSubTypedIndex = -1;
    duration = Duration.zero;

    await session.applyDirectPlayTuning(PlaybackProfiles.current);
    // Back to the file's own tracks: load straight onto the language the user
    // was listening to, instead of the container default followed by a switch.
    await _applyPreferredAudioLanguage(_selectedAudioLang);
    final streamUrl = _apiClient!.getStreamUrl(_media!.id);
    // Open straight at the position the HLS session was left at. The previous
    // shape — open at 0, wait out a full buffering cycle, seek, wait again —
    // buffered the head of the file for nothing and made every switch back to
    // Direct Play take several seconds of spinner.
    _openedAtSeconds = savedSeconds > 0 ? savedSeconds : 0;
    await session.open(
      streamUrl,
      start: savedSeconds > 0 ? Duration(seconds: savedSeconds) : null,
      play: true,
    );
    if (savedSeconds > 0) {
      position = Duration(seconds: savedSeconds);
      _onPositionChanged?.call();
    }

    _reapplySelectionsAfterLoad();

    isSwitchingQuality = false;
    _onQualitySwitchingChanged?.call();
  }

  /// Small tolerance for forward seeks, used only as a floor under the player's
  /// own buffered position so a one-second rounding difference does not force a
  /// full session rebuild.
  static const _hlsForwardSeekTolerance = 2;

  /// Hard ceiling on how far ahead an in-session forward seek may land.
  ///
  /// Sized against the server's just-in-time window (32s), because that is the
  /// most the encoder is ever allowed to run ahead — anything past it provably
  /// does not exist yet. Rebuilding instead costs a measured 3-6s, so this
  /// caps the worst case at "briefly wait for content already being written"
  /// rather than "wait for two minutes of video to be encoded in order".
  static const _maxForwardCatchUpSeconds = 30;

  /// Whether [absoluteSeconds] can be reached by seeking inside the running HLS
  /// session, without transcoding anything new.
  ///
  /// Backwards is decided structurally, forwards is decided by measurement —
  /// and the difference matters:
  ///
  ///   - Backwards, down to the session's own start offset, is always safe. The
  ///     playlist is append-only (EXT-X-PLAYLIST-TYPE:EVENT) and segments are
  ///     never deleted, so anything the playhead has already passed is still on
  ///     disk. This is the case worth optimising: rewinding used to throw away
  ///     the whole transcode and start over.
  ///
  ///   - Forwards is capped by what the player has ACTUALLY buffered. It is
  ///     tempting to assume the server's just-in-time window (~32s ahead) is
  ///     always filled, but that only holds while the encoder outruns playback.
  ///     A CPU-bound 4K transcode sits at roughly real-time or below, so that
  ///     buffer frequently does not exist — and seeking into it lands on
  ///     segments that were never produced, leaving the player waiting forever
  ///     on files that will not arrive until the encoder eventually catches up.
  ///     Asking the player how far it has really buffered removes the guess.
  ///
  /// When the buffer reading is unavailable or zero, forward seeks simply fall
  /// back to rebuilding the session — the conservative behaviour.
  bool canSeekWithinSession(int absoluteSeconds) {
    if (currentQuality == null) return true;
    // Before this session's timeline begins: unreachable without a new session.
    if (absoluteSeconds < _hlsStartOffset) return false;

    if (absoluteSeconds <= position.inSeconds) return true;

    // Two independent limits, and the seek must satisfy BOTH.
    //
    // The encoder writes segments strictly in order, so an in-session forward
    // seek is only instant if the target is already on disk. Overshoot it and
    // the player waits for everything in between to be encoded — for a jump of
    // a couple of minutes that is far worse than the 3-6s a fresh session costs,
    // and it is what "I have to wait for it to do it all" describes.
    //
    //   - the player's own cache end, which is what is genuinely downloaded;
    //   - a hard ceiling, so a cache reading that is optimistic or stale can
    //     never authorise a jump into content nobody has encoded yet.
    final ceiling = position.inSeconds + _maxForwardCatchUpSeconds;
    final buffered = _bufferedAbsoluteSeconds();
    final reachable = buffered < ceiling ? buffered : ceiling;
    return absoluteSeconds <= reachable + _hlsForwardSeekTolerance;
  }

  /// Absolute second up to which the player currently holds buffered media.
  int _bufferedAbsoluteSeconds() {
    try {
      final buffered = session.bufferedAhead.inSeconds;
      if (buffered <= 0) return position.inSeconds;
      return buffered + _hlsStartOffset;
    } catch (_) {
      return position.inSeconds;
    }
  }

  /// Seek to an absolute position in the media.
  ///
  /// In HLS this rebuilds the session only when the target is outside what the
  /// current one can serve. Rewinding — the common case, and previously a full
  /// re-transcode with a spinner — is now a plain seek through already-produced
  /// segments.
  Future<void> seekToAbsoluteSeconds(int absoluteSeconds) async {
    final target = absoluteSeconds < 0 ? 0 : absoluteSeconds;

    if (currentQuality == null) {
      await session.seek(Duration(seconds: target));
      return;
    }

    final within = canSeekWithinSession(target);
    // Logs the whole decision, because "seek does nothing" and "seek rebuilds
    // the session" look identical from the outside: it shows whether a stall is
    // a seek that stayed inside a session it should have left, or a rebuild
    // that is simply slow.
    debugPrint("SEEK: target=${target}s pos=${position.inSeconds}s "
        "offset=${_hlsStartOffset}s buffered=${_bufferedAbsoluteSeconds()}s "
        "-> ${within ? 'seek in session' : 'rebuild session'}");

    if (!within) {
      await reloadHlsAtPosition(target);
      return;
    }
    // Reflect the target before awaiting mpv, so the bar tracks the click even
    // when the seek itself takes a moment to settle.
    position = Duration(seconds: target);
    _onPositionChanged?.call();
    await session.seek(Duration(seconds: target - _hlsStartOffset));
  }

  // ==================== Audio / subtitle selection ====================

  /// Select an audio track by canonical index.
  ///
  ///   - Direct Play: switch natively and instantly (all tracks are present).
  ///   - HLS: the session publishes every audio track as a rendition of one
  ///     group, so this is also just an mpv track switch — instant, no spinner,
  ///     no re-transcode. Only a track the session did not publish (a file with
  ///     more languages than the rendition cap) needs a fresh session.
  Future<void> switchAudioTrack(int index) async {
    if (mediaTracks == null) return;
    if (index < 0 || index >= mediaTracks!.audio.length) return;
    if (index == _selectedAudioIndex) return;
    _selectedAudioIndex = index;

    // A browser offers no audio-track API over a media stream, and media_kit's
    // web setAudioTrack only accepts a URI — the rendition switch that is free
    // on desktop simply does nothing here. The server already takes the wanted
    // track as `?audio=N` at session start, so the switch is a new session:
    // ~2s of spinner instead of instant, but it actually changes the language.
    if (AppPlatform.isWeb) {
      if (currentQuality == null) {
        await _startWebTranscode();
      } else {
        await reloadHlsAtPosition(position.inSeconds);
      }
      return;
    }

    if (currentQuality != null && _playerAudioPosition(index) == null) {
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
      final tracks = session.subtitleTracks;
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
  /// Bitmap stream the transcoder must paint into the video to show [lang], or
  /// -1 when the language needs no burn-in (text track, or subtitles off).
  int _burnIndexFor(String? lang) {
    if (lang == null || lang.isEmpty) return -1;
    final track = _trackForLang(lang);
    if (track == null || !track.image) return -1;
    return track.typedIndex;
  }

  Future<void> setSubtitle(String? lang) async {
    if (_media == null || _apiClient == null) return;
    _selectedSubtitleLang = lang;
    _selectedInternalSubId = null;
    _subtitlesExplicitlyOff = lang == null || lang.isEmpty;

    // While transcoding, a bitmap track lives in the picture itself, so turning
    // one on — or off, or swapping it for another — changes what has to be
    // encoded. That is the only subtitle change that costs a new session; text
    // tracks stay out of band and switch instantly.
    if (currentQuality != null) {
      final wanted = _burnIndexFor(lang);
      if (wanted != _hlsBurnedSubTypedIndex) {
        _hlsBurnedSubTypedIndex = wanted;
        await reloadHlsAtPosition(position.inSeconds);
        return;
      }
    }

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
  /// remember it (mpv id + the server's canonical language key) so the choice
  /// survives a reload and carries over to HLS without the user ever seeing the
  /// source change.
  void selectInternalSubtitle(PlaybackTrack track) {
    final isOff = track.id == 'no';
    _selectedInternalSubId = isOff ? null : track.id;
    _selectedSubtitleLang = isOff ? null : _canonicalLangForEmbedded(track);
    _subtitlesExplicitlyOff = isOff;
    try {
      session.setSubtitles(SubtitleSelection.track(track));
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

  List<PlaybackTrack> _realAudioTracks() => session.audioTracks
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  /// Position of a canonical audio index in the player's track list.
  ///
  /// Direct Play enumerates the file's own tracks, so the canonical index is the
  /// position. HLS enumerates only the renditions the session published, so the
  /// server's audio map translates between the two. Returns null when the track
  /// is not part of the current session.
  int? _playerAudioPosition(int canonicalIndex) {
    if (currentQuality == null) return canonicalIndex;
    final pos = _hlsAudioMap.indexOf(canonicalIndex);
    return pos < 0 ? null : pos;
  }

  void _applyAudioSelection() {
    final real = _realAudioTracks();
    if (real.isEmpty) return;
    final pos = _playerAudioPosition(_selectedAudioIndex);
    if (pos == null) return; // not published by this session
    final i = pos.clamp(0, real.length - 1);
    try {
      session.setAudioTrack(real[i]);
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
    //
    // Except in a browser, which cannot see a file's embedded subtitle tracks at
    // all — a <video> knows only <track> elements. There the external WebVTT is
    // the only source there has ever been, Direct Play included.
    if (currentQuality == null && !AppPlatform.isWeb) {
      _applyInternalSubtitleSelection();
      return;
    }

    final lang = _selectedSubtitleLang;
    final reqId = ++_subtitleRequestId;

    // Always clear the current external subtitle first. mpv's `sub-add ... select`
    // does NOT reliably switch the active selection when another external track
    // is already loaded (the second language would never show). Going through
    // `no()` first forces a clean re-selection. This also handles "off".
    if (AppPlatform.isWeb) {
      WebPlayback.clearSubtitles();
    } else {
      try {
        session.setSubtitles(const SubtitleSelection.none());
        debugPrint("SUB: cleared current subtitle before applying selection");
      } catch (_) {}
    }

    if (lang == null || lang.isEmpty) {
      _attachedSubtitleSignature = null;
      return;
    }

    // A bitmap track is already painted into the video by the transcoder, so
    // there is no external file to attach — and mpv must stay on "no" or it
    // would render nothing on top of an already-subtitled picture.
    if (_trackForLang(lang)?.image ?? false) {
      _attachedSubtitleSignature = null;
      return;
    }
    _attachedSubtitleSignature = _subtitleSignature(lang);

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
    _apiClient!
        .fetchSubtitleContent(mediaId, lang, start: start)
        .then((vtt) async {
      // Ignore stale responses (selection changed while we were fetching).
      if (_disposed || reqId != _subtitleRequestId) {
        debugPrint(
            "SUB: #$reqId stale (current=$_subtitleRequestId), skipping");
        return;
      }
      final cueCount = '-->'.allMatches(vtt).length;
      if (cueCount == 0) {
        debugPrint(
            "SUB: #$reqId lang=$lang has NO cues (${vtt.length} chars) — nothing to show");
        return;
      }
      debugPrint(
          "SUB: #$reqId lang=$lang fetched ${vtt.length} chars, $cueCount cues");
      try {
        if (AppPlatform.isWeb) {
          // Never media_kit's setSubtitleTrack here: it installs an oncuechange
          // handler that throws on every cue and prints a stack trace with it,
          // which starves the main thread and freezes the picture while the
          // sound carries on. Handing the cues to the browser also keeps them
          // visible in native full screen.
          WebPlayback.showSubtitleVtt(vtt, language: lang, label: title);
          debugPrint("SUB: #$reqId applied via browser text track (lang=$lang)");
          return;
        }
        await session.setSubtitles(
          SubtitleSelection.vtt(vtt, title: title, language: lang),
        );
        // Read state only AFTER the command has actually run, plus a tick for
        // mpv's track-list event to propagate back.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_disposed) return;
        final subs = session.subtitleTracks.map((t) => t.id).toList();
        debugPrint("SUB: #$reqId applied. engine subtitle tracks: $subs, "
            "active=${session.currentSubtitleTrack?.id}");
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
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {}
      return;
    }

    if (_selectedInternalSubId == null && _selectedSubtitleLang == null) {
      try {
        session.setSubtitles(const SubtitleSelection.none());
      } catch (_) {}
      return;
    }

    final tracks = session.subtitleTracks;
    if (tracks.isEmpty) return;

    PlaybackTrack? match;
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
        if (_canonicalLangForEmbedded(t) == _selectedSubtitleLang) {
          match = t;
          break;
        }
      }
    }
    try {
      session.setSubtitles(
        match == null
            ? const SubtitleSelection.none()
            : SubtitleSelection.track(match),
      );
    } catch (_) {}
  }

  /// Canonical language key of an embedded subtitle track, read from the
  /// server's list instead of derived here.
  ///
  /// mpv numbers a file's subtitle tracks 1..N in container order — the same
  /// order ffprobe reports them — so `id - 1` is the typed index (0:s:N) the
  /// server keys its canonical entries by.
  ///
  /// This used to be a local mapping table, which is what broke the Direct Play
  /// → HLS carry-over: it disagreed with the server's for `pol` (po vs pl),
  /// `tur` (tu vs tr), `swe` (sw vs sv), `ces`/`cze` (ce/cz vs cs), and it
  /// truncated every 3-letter code the server left untouched (`heb` → `he`).
  /// Picking a subtitle in Direct Play then switching to HLS silently lost it.
  /// There is now exactly one place where a language code is decided: the server.
  String? _canonicalLangForEmbedded(PlaybackTrack? track) {
    if (track == null) return null;
    final sid = int.tryParse(track.id);
    if (sid == null) return null; // "no" / "auto" / a track we attached ourselves
    final typedIndex = sid - 1;
    for (final s in mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[]) {
      if (s.typedIndex == typedIndex) return s.lang;
    }
    return null;
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

    _reapplySubscription = session.trackChanges.listen((_) {
      final hasAudio = session.audioTracks
          .any((e) => e.id != 'auto' && e.id != 'no');
      if (hasAudio) apply();
    });
    Timer(const Duration(milliseconds: 1500), apply);
  }

  // ==================== HLS helpers ====================

  void _forceDuration(double totalDurationSeconds) {
    if (totalDurationSeconds <= 0) return;
    duration = Duration(seconds: totalDurationSeconds.round());
    unawaited(session.overrideDuration(
      Duration(milliseconds: (totalDurationSeconds * 1000).round()),
    ));
    _onDurationChanged?.call();
  }

  /// Hide the spinner once buffering has started and then stopped (the stream
  /// is actually playing), with a safety timeout.
  void _hideLoadingAfterBuffer() {
    StreamSubscription? sub;
    var sawBuffering = false;
    sub = session.bufferingChanges.listen((isBuffering) {
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
    _bufferingSubscription?.cancel();
    _reapplySubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription = null;
    _completedSubscription = null;
    _playingSubscription = null;
    _videoParamsSubscription = null;
    _bufferingSubscription = null;
    _reapplySubscription = null;
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
  }

  void dispose() {
    // Before `_disposed`, so the property reads still go through.
    unawaited(_logDropCounters());
    // The catalogue is not 24 fps: a panel left at a film's rate makes every
    // scroll in the app judder instead.
    unawaited(DisplayFrameRate.release());
    _disposed = true;
    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = null;
    _stopSubtitleWatch();
    _tracksStreamController.close();
    _heartbeatTimer?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    // The engine outlives this controller now, so a subscription left behind
    // here would keep calling into a dead one for the whole next playback.
    _playingSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _reapplySubscription?.cancel();
    if (_hlsSessionId != null && _media != null && _apiClient != null) {
      _apiClient!.destroyHlsSession(_media!.id, _hlsSessionId!);
    }
    _hlsSessionId = null;
    // Leaving the player screen must not leave hls.js segment loaders running
    // against a <video> that is about to disappear.
    WebPlayback.clearSubtitles();
    WebPlayback.releaseAllHlsSessions();
    // Handed back rather than destroyed: the next playback reuses this libmpv
    // instance and its texture instead of paying to build them again.
    PlayerEnginePool.release(_engine);
  }
}
