import 'dart:async';
import 'package:flutter/material.dart';
import '../../../models/models.dart';
import '../../../models/series_track_preferences.dart';
import '../../../models/server_activity.dart';
import '../../../utils/app_platform.dart';
import '../web/web_playback.dart';
import '../display_frame_rate.dart';
import '../hardware_decoding.dart';
import '../playback/auto_quality.dart';
import '../playback/carried_subtitle.dart';
import '../playback/embedded_subtitle_pairing.dart';
import '../playback/hls_retain_window.dart';
import '../playback/live_subtitles.dart';
import '../playback/playback_engine.dart';
import '../playback/playback_session.dart';
import '../playback/playback_stats.dart';
import '../playback/series_track_memory.dart';
import '../playback/startup_timeline.dart';
import 'playback_reporter.dart';
import 'use_auto_quality.dart';
import '../playback/timeline_previews.dart';
import '../playback_profile.dart';
import '../web_quality.dart';
import '../../../services/api_client.dart';
import '../../../services/client_log.dart';
import '../../../services/playback_access.dart';
import '../../../services/dns_warmup.dart';
import '../../../services/download_manager.dart';
import '../../../services/hls_preload.dart';
import '../../../services/playback_capabilities.dart';
import '../../../services/playback_preferences_storage.dart';
import '../player_playback_preferences.dart';

// Le contrôleur est découpé par sujet : ce fichier garde l'état, le signal
// de première image, les préférences héritées, le rapport au serveur et le
// démontage. Le reste est dans des extensions, une par sujet. Voir ADR-0052.
part 'player_controller_auto.dart';
part 'player_controller_hls.dart';
part 'player_controller_startup.dart';
part 'player_controller_tracks.dart';

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
///   - Subtitles: in Direct Play the engine reads the file's own tracks. While
///     transcoding, the session writes every text track as a WebVTT that grows
///     with it, and [liveSubtitles] paints it over the picture (ADR-0031). A
///     server older than that falls back to the .vtt files it extracts ahead,
///     injected into the engine.
class PlayerController {
  PlaybackAccess? _playbackAccess;

  /// The stills above the scrubber. Null until the first frame is on screen,
  /// and for good on a downloaded file, which has no server to draw them.
  TimelinePreviews? timelinePreviews;

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

  /// La panne qui a arrêté le démarrage, quand le moteur en a rapporté une.
  ///
  /// Lue par l'écran, qui affiche son message plutôt que d'attendre le délai de
  /// démarrage : une panne connue à la seconde deux n'a aucune raison d'être
  /// annoncée à la seconde vingt-cinq.
  PlaybackFailure? startupFailure;

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
      // Le tampon qui se remplit au démarrage n'est pas une ligne qui cale.
      _noteDisturbance();
      _mark('shown');
      _printStartup();
      _startTimelinePreviews();
      _onFirstFrame?.call();
      unawaited(_onPictureLive());
    });
  }

  /// Starts the timeline stills — never earlier than the first frame, so the
  /// server's extraction work cannot slow down the start of playback.
  void _startTimelinePreviews() {
    final access = _playbackAccess;
    final media = _media;
    final api = _apiClient;
    if (timelinePreviews != null ||
        access == null ||
        access.isLegacy ||
        media == null ||
        api == null) {
      return;
    }
    final previews = TimelinePreviews(
      open: () => api.openTimelinePreviews(media.id, access: access),
      fetch: (index) =>
          api.fetchTimelinePreview(media.id, index, access: access),
    );
    timelinePreviews = previews;
    unawaited(previews.start());
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

  /// Whether this playback only ever goes through an HLS session.
  ///
  /// A browser cannot open the containers and codecs a private library is made
  /// of: the web skips Direct Play and starts a session as soon as the track
  /// list says which tier to ask for. Every native engine opens the file
  /// itself — AetherEngine included on Apple devices (ADR-0038).
  bool get _hlsOnly => AppPlatform.isWeb;

  /// In HLS mode the stream timeline resets to 0 at this offset (seconds) into
  /// the original media. Used to display the absolute position and to compute
  /// seek targets. 0 in Direct Play.
  int _hlsStartOffset = 0;
  int get hlsStartOffset => _hlsStartOffset;

  /// Current transcoding quality. null = Direct Play.
  String? currentQuality;
  String? _hlsSessionId;

  /// `copy` or `encode`, as the server reported for the current HLS session.
  String _hlsVideoMode = '';

  /// La qualité automatique de cette lecture. Voir [AutoQualityPilot] et
  /// ADR-0056.
  late final AutoQualityPilot _auto = AutoQualityPilot(
    read: _autoReading,
    measureLine: _measureLine,
    move: _autoMove,
  );

  /// Cet appareil ne lit pas ce fichier lui-même (codec ou piste audio qu'il
  /// ne décode pas) : l'Auto ne remonte pas plus haut que [_autoCeilingKey],
  /// le barreau pris à la place du Direct Play.
  bool _directPlayRuledOut = false;
  String? _autoCeilingKey;

  /// Le serveur recopie l'image de ce barreau-là : il pèse ce que pèse le
  /// fichier, pas son débit affiché.
  bool _autoCeilingCopies = false;

  /// Change à chaque fois que quelqu'un reprend la main sur la lecture : une
  /// bascule en préparation qui ne retrouve pas le sien renonce.
  int _handoffEpoch = 0;
  bool _handoffInFlight = false;

  /// La session préparée à côté de celle qui est lue, à rendre au serveur si
  /// le lecteur se ferme avant de l'avoir prise.
  String? _preparedSessionId;

  /// Le relais local par lequel le moteur lit la session en cours, quand son
  /// début a été téléchargé d'avance. Voir [HlsPreload].
  HlsPreload? _hlsPreload;

  /// Jusqu'à quand le sablier se tait derrière un changement de source
  /// préparé : le moteur regarnit son tampon, et ça ne se montre que si ça
  /// dure.
  DateTime? _quietSwapUntil;

  /// La vitesse de lecture choisie, que l'écran tient à jour : à 2×, le
  /// tampon fond deux fois plus vite sans que la ligne y soit pour rien.
  double playbackSpeed = 1;

  /// Les mesures de cette séance. Voir [PlaybackStatsCollector].
  final PlaybackStatsCollector _stats = PlaybackStatsCollector();

  /// Ce que le lecteur dit au serveur pendant qu'il lit. Voir
  /// [PlaybackReporter].
  late final PlaybackReporter _reporter =
      PlaybackReporter(moment: _playbackMoment, stats: _stats);

  /// Chemin du fichier local quand ce média est téléchargé, sinon null.
  ///
  /// Résolu une fois à l'ouverture et jamais relu : le fichier ne peut pas
  /// disparaître sous le lecteur (la suppression demande confirmation depuis un
  /// autre écran), et une lecture qui hésiterait entre deux sources en cours de
  /// route serait pire que tout.
  ///
  /// Une copie locale l'emporte sur le flux même en ligne : elle démarre sans
  /// mise en mémoire tampon, survit à une coupure au milieu de l'épisode, et ne
  /// coûte rien au serveur.
  String? _localFilePath;

  /// Vrai quand l'image vient du disque et non du réseau.
  bool get isLocalPlayback => _localFilePath != null;

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
  VoidCallback? _onFailure;
  VoidCallback? _onPlayingChanged;

  /// Les sous-titres texte de la session HLS en cours, lus pendant que le
  /// serveur les écrit, et peints au-dessus de l'image. Voir ADR-0031.
  final LiveSubtitleFeed liveSubtitles = LiveSubtitleFeed();

  /// Les pistes que la session HLS en cours écrit elle-même, ou null hors HLS
  /// et face à un serveur qui ne sait pas le faire — c'est alors l'extraction
  /// d'avant qui sert.
  List<LiveSubtitleSource>? _hlsLiveSubtitles;

  /// Ce que la session HLS en cours garde derrière elle ; null : tout.
  int? _hlsRetainSeconds;

  /// La qualité de la session en train de s'ouvrir, pendant l'ouverture.
  String? _hlsQualityInFlight;

  /// La dernière ouverture demandée pendant qu'une autre était en cours.
  ({String quality, int startSeconds})? _pendingHlsOpen;

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

  /// True once [startPlayback] has asked the engine to play.
  bool _playbackStarted = false;

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

  /// Le sous-titre hérité de l'épisode précédent, tant que l'utilisateur n'en
  /// a pas choisi un autre ici. C'est lui qui passe à l'épisode suivant, et non
  /// ce qu'on a trouvé à sa place : un épisode sans piste forcée n'affiche rien,
  /// et le suivant doit reprendre la forcée, pas ce « rien ».
  CarriedSubtitle? _carriedSubtitle;

  /// Ce que le compte retient pour la série de l'épisode en cours, ou null
  /// hors d'une série. Voir [SeriesTrackMemory].
  SeriesTrackMemory? _seriesMemory;

  /// Le sous-titre qu'on vient de choisir à la main vaut désormais pour la
  /// série. Une piste que le catalogue ne sait pas nommer n'est pas retenue :
  /// rien ne permettrait de la retrouver dans un autre épisode.
  void _rememberSubtitleChoice() {
    final memory = _seriesMemory;
    if (memory == null) return;
    if (_subtitlesExplicitlyOff) {
      memory.rememberSubtitle(const SeriesSubtitleChoice.off());
      return;
    }
    final key = _selectedSubtitleLang;
    if (key == null || key.isEmpty) return;
    final track = _trackForLang(key);
    final carried =
        track != null ? CarriedSubtitle.of(track) : CarriedSubtitle.fromKey(key);
    memory.rememberSubtitle(carried.asSeriesChoice);
  }

  Future<String?> _loadDefaultAudioLang() async {
    try {
      return await PlaybackPreferencesStorage().loadDefaultAudioLang();
    } catch (_) {
      return null;
    }
  }

  /// La langue audio héritée, tant qu'on n'en a pas choisi une autre ici. Même
  /// raison que [_carriedSubtitle] : un épisode qui n'a pas cette langue joue
  /// autre chose, et le suivant doit reprendre la langue voulue, pas ce repli.
  String? _carriedAudioLang;

  PlayerPlaybackPreferences exportPreferences() {
    final exported = _exportCurrentSelection();
    final audioLang = _carriedAudioLang;
    if (audioLang == null || audioLang == exported.audioLang) return exported;
    return PlayerPlaybackPreferences(
      audioIndex: exported.audioIndex,
      audioLang: audioLang,
      subtitle: exported.subtitle,
      internalSubId: exported.internalSubId,
      subtitlesOff: exported.subtitlesOff,
    );
  }

  PlayerPlaybackPreferences _exportCurrentSelection() {
    if (_carriedSubtitle != null) {
      return PlayerPlaybackPreferences(
        audioIndex: _selectedAudioIndex,
        audioLang: _selectedAudioLang,
        subtitle: _carriedSubtitle,
        internalSubId: _selectedInternalSubId,
        subtitlesOff: false,
      );
    }

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

    final key = _selectedSubtitleLang ?? _canonicalLangForEmbedded(track);
    final canonical = key == null ? null : _trackForLang(key);
    return PlayerPlaybackPreferences(
      audioIndex: _selectedAudioIndex,
      audioLang: _selectedAudioLang,
      subtitle: canonical != null
          ? CarriedSubtitle.of(canonical)
          : key == null
              ? null
              : CarriedSubtitle.fromKey(key),
      internalSubId: _selectedInternalSubId ?? track.id,
      subtitlesOff: false,
    );
  }

  void _applyInheritedPreferences(
    PlayerPlaybackPreferences prefs, {
    String? defaultAudioLang,
  }) {
    _selectedAudioIndex = prefs.audioIndexIn(
      mediaTracks?.audio ?? const <MediaAudioTrack>[],
      defaultLang: defaultAudioLang,
    );
    _carriedAudioLang = prefs.audioLang;

    _subtitlesExplicitlyOff = prefs.subtitlesOff;
    _carriedSubtitle = prefs.subtitlesOff ? null : prefs.subtitle;
    final wanted = _carriedSubtitle;
    final subs = mediaTracks?.subtitles ?? const <MediaSubtitleTrack>[];
    if (prefs.subtitlesOff) {
      _selectedSubtitleLang = null;
      _selectedInternalSubId = null;
    } else if (wanted == null || subs.isEmpty) {
      // Rien à quoi comparer : la clé telle quelle, et l'id mpv en dernier
      // recours. Appelé une seconde fois quand la liste des pistes arrive.
      _selectedSubtitleLang = wanted?.key;
      _selectedInternalSubId = prefs.internalSubId;
    } else {
      final match = wanted.matchIn(subs);
      _selectedSubtitleLang = match?.lang;
      // L'id mpv ne vaut que dans le média d'où il vient : la piste retrouvée
      // se désigne par sa clé, qui mène à la bonne piste embarquée.
      _selectedInternalSubId = null;
      if (match == null) _subtitlesExplicitlyOff = true;
    }
  }

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
  StreamSubscription? _failureSubscription;
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

  /// Milestones of the current start-up. See [StartupTimeline].
  ///
  /// Started with the controller, which the screen builds in `initState` :
  /// what the screen does before calling [init] shows up as the `init` step.
  final StartupTimeline _startup = StartupTimeline()..start();

  void _mark(String label) => _startup.mark(label);

  /// The clock is running: that is the start-up the stats report.
  void _notePlaying() {
    final millis = _startup.notePlaying();
    if (millis != null) _stats.noteStartup(millis);
  }

  /// Prints the start-up line, once. An unfinished one is printed too — on the
  /// way out — since a start that never lands is the one worth reading.
  void _printStartup({bool complete = true}) {
    final line = _startup.close(complete: complete);
    if (line != null) debugPrint(line);
  }

  PlayerController() {
    session = createPlaybackSession();
  }

  /// Signature of the external subtitle currently attached in HLS mode. The poll
  /// loop re-attaches only when this changes — first availability, or a
  /// head-only track being replaced by the complete one — instead of re-fetching
  /// and flickering the track on every tick.
  String? _attachedSubtitleSignature;

  /// Monotonic token guarding against out-of-order subtitle loads (the user
  /// switching language quickly, or a reload firing mid-fetch).
  int _subtitleRequestId = 0;

  // ==================== Heartbeat / progress ====================

  void _setPlaying(bool playing) {
    if (isPlaying == playing) return;
    isPlaying = playing;
    if (playing) _reporter.reclaimProgress();
    _onPlayingChanged?.call();
  }

  void _setBuffering(bool buffering) {
    if (isBuffering == buffering) return;
    final quietUntil = _quietSwapUntil;
    if (buffering && quietUntil != null) {
      _quietSwapUntil = null;
      final left = quietUntil.difference(DateTime.now());
      if (left > Duration.zero) {
        final seen = position;
        Timer(left, () {
          // mpv se dit encore « en tampon » deux secondes après avoir repris,
          // pendant que l'image défile : seul un film qui n'avance pas mérite
          // le sablier.
          final moving =
              position - seen > const Duration(milliseconds: 500);
          if (!_disposed && session.isBuffering && !moving) {
            _setBuffering(true);
          }
        });
        return;
      }
    }
    isBuffering = buffering;
    _stats.noteBuffering(buffering);
    _onBufferingChanged?.call();
    if (buffering) unawaited(_auto.noteStall());
  }

  void togglePlayPause() {
    final next = !isPlaying;
    _setPlaying(next);
    if (next) {
      // Une reprise regarnit le tampon : ce n'est pas la ligne qui cale.
      _noteDisturbance();
      session.play();
    } else {
      session.pause();
    }
  }

  void startHeartbeat({required int mediaId, required ApiClient apiClient}) =>
      _reporter.startHeartbeat(mediaId: mediaId, apiClient: apiClient);

  PlayMethod get playMethod {
    if (_localFilePath != null) return PlayMethod.local;
    if (currentQuality == null) return PlayMethod.direct;
    return _hlsVideoMode == 'copy' ? PlayMethod.directStream : PlayMethod.transcode;
  }

  /// L'instant de la lecture pour [PlaybackReporter]. La durée retombe sur
  /// celle que le serveur connaît tant que le moteur n'a pas donné la sienne.
  PlaybackMoment _playbackMoment() {
    var durSeconds = duration.inSeconds;
    if (durSeconds <= 0 && _knownDurationSeconds > 0) {
      durSeconds = _knownDurationSeconds;
    }
    return (
      positionSeconds: position.inSeconds,
      durationSeconds: durSeconds,
      playing: session.isPlaying,
      method: playMethod,
      quality: currentQuality ?? '',
    );
  }

  /// Annonce que la lecture reprend ici : le serveur met en pause, chez les
  /// autres appareils du compte, ce même titre (voir `playback_handoff.go`).
  void announcePlaybackHere() {
    final media = _media;
    final api = _apiClient;
    if (media == null || api == null) return;
    _reporter.announceHere(mediaId: media.id, apiClient: api);
  }

  /// Ce que le lecteur dit au serveur. Exposé pour la reprise entre
  /// appareils (voir `away_from_screen.dart`), qui en règle la progression.
  PlaybackReporter get reporter => _reporter;

  void _reportActivityStopped() {
    final media = _media;
    final api = _apiClient;
    if (media == null || api == null) return;
    _reporter.stop(mediaId: media.id, apiClient: api);
  }

  Future<void> finishPlayback({
    required int mediaId,
    required ApiClient apiClient,
    bool isFinished = false,
  }) =>
      _reporter.finish(
          mediaId: mediaId, apiClient: apiClient, isFinished: isFinished);

  // ==================== Teardown ====================

  Future<void> _releasePlaybackAccess() async {
    final access = _playbackAccess;
    final sessionIds = [_hlsSessionId, _preparedSessionId].nonNulls.toList();
    _playbackAccess = null;
    _hlsSessionId = null;
    _preparedSessionId = null;
    _hlsPreload?.close();
    _hlsPreload = null;
    if (_media != null && _apiClient != null) {
      for (final sessionId in sessionIds) {
        await _apiClient!
            .destroyHlsSession(_media!.id, sessionId, access: access);
      }
    }
    await access?.close();
  }

  void _disposeTimelinePreviews() {
    timelinePreviews?.dispose();
    timelinePreviews = null;
  }

  void cancelStreams() {
    _printStartup(complete: false);
    _auto.stop();
    _reportActivityStopped();
    _stats.stop();
    _disposeTimelinePreviews();
    unawaited(_releasePlaybackAccess());
    _disposed = true;
    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = null;
    _stopSubtitleWatch();
    liveSubtitles.stop();
    _reporter.cancelHeartbeat();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _playingSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _reapplySubscription?.cancel();
    _failureSubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription = null;
    _completedSubscription = null;
    _playingSubscription = null;
    _videoParamsSubscription = null;
    _bufferingSubscription = null;
    _reapplySubscription = null;
    _failureSubscription = null;
  }

  void dispose() {
    _printStartup(complete: false);
    _auto.stop();
    _reportActivityStopped();
    _stats.stop();
    _disposeTimelinePreviews();
    unawaited(_releasePlaybackAccess());
    // Before `_disposed`, so the property reads still go through.
    unawaited(_logDropCounters());
    // The catalogue is not 24 fps: a panel left at a film's rate makes every
    // scroll in the app judder instead.
    unawaited(DisplayFrameRate.release());
    _disposed = true;
    _deferredSubtitleExtractTimer?.cancel();
    _deferredSubtitleExtractTimer = null;
    _stopSubtitleWatch();
    liveSubtitles.dispose();
    _tracksStreamController.close();
    _reporter.cancelHeartbeat();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    // The engine outlives this controller now, so a subscription left behind
    // here would keep calling into a dead one for the whole next playback.
    _playingSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _reapplySubscription?.cancel();
    _failureSubscription?.cancel();
    // Leaving the player screen must not leave hls.js segment loaders running
    // against a <video> that is about to disappear.
    WebPlayback.clearSubtitles();
    WebPlayback.releaseAllHlsSessions();
    // Rendre le moteur : sans ça, ce qui vit derrière garde son décodeur, sa
    // connexion et son audio, et un film qu'on vient de quitter continue de
    // s'entendre.
    unawaited(session.dispose());
  }
}
