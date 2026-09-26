import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:onyx_player_apple/onyx_player_apple.dart';

import '../../../services/client_log.dart';
import '../playback_profile.dart';
import 'aether_tracks.dart';
import 'native_video_framing.dart';
import 'playback_session.dart';
import 'screen_awake.dart';
import 'subtitle_bitmap_overlay.dart';
import 'subtitle_overlay.dart';

/// [PlaybackSession] adossée à AetherEngine, sur iPhone, Mac et Apple TV —
/// voir l'ADR-0038.
///
/// Le serveur envoie le fichier tel quel. AetherEngine le démultiplexe sur
/// l'appareil et le donne à AVPlayer (Dolby Vision, Atmos, décodeur matériel),
/// ou le décode lui-même quand AVPlayer ne sait pas (AV1 sans décodeur
/// matériel, VP9, MPEG-2, VC-1). L'image passe par une vue native, jamais par
/// une texture, qui serait en 8 bits.
///
/// Tout le reste (reprise, sessions HLS, heartbeat, pistes, préférences)
/// appartient au contrôleur partagé. Comme pour ExoPlayer, cette classe ne
/// fait que traduire.
class AetherPlaybackSession implements PlaybackSession {
  /// Construite tout de suite, prête un peu après : le contrôleur construit sa
  /// session dans son constructeur, et l'écran demande la surface avant que
  /// quoi que ce soit ne soit chargé. Même montage qu'`ExoPlaybackSession`.
  AetherPlaybackSession() {
    _forwardEngineLog();
    _ready = OnyxApplePlayer.create().then((player) {
      _statusSubscription = player.statuses.listen(_onStatus);
      _subtitleSubscription = player.subtitles.listen(_onSubtitles);
      return player;
    });
  }

  late final Future<OnyxApplePlayer> _ready;
  StreamSubscription<OnyxApplePlayerStatus>? _statusSubscription;
  StreamSubscription<OnyxAppleSubtitleFrame>? _subtitleSubscription;

  /// Le journal d'AetherEngine part dans celui de l'app (ADR-0026), une seule
  /// fois pour tout le processus : deux lecteurs vivants à la fois, au passage
  /// d'un épisode, doubleraient sinon chaque ligne.
  static StreamSubscription<List<String>>? _engineLog;

  static void _forwardEngineLog() {
    _engineLog ??= OnyxApplePlayer.engineLog.listen((lines) {
      for (final line in lines) {
        debugPrint('AetherEngine: $line');
      }
    }, onError: (Object error) {
      debugPrint('AetherEngine: journal interrompu ($error)');
    });
  }

  OnyxApplePlayerStatus? _status;
  AetherTracks _tracksNow = AetherTracks.empty;

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _tracks = StreamController<void>.broadcast();
  final _videoParams = StreamController<PlaybackVideoParams>.broadcast();
  final _failures = StreamController<PlaybackFailure>.broadcast();

  Duration _lastPosition = Duration.zero;
  Duration _nativeDuration = Duration.zero;
  Duration? _durationOverride;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _lastEnded = false;
  int _lastTrackCount = -1;
  PlaybackFailure? _lastFailure;
  final ValueNotifier<PlaybackVideoParams> _params =
      ValueNotifier(PlaybackVideoParams.unknown);

  /// L'app parle en 0..100, comme mpv ; le moteur en 0..1. Retenu ici, faute
  /// d'être relu du natif.
  double _volume = 100;

  /// Les répliques texte à afficher maintenant, peintes par [SubtitleOverlay].
  final ValueNotifier<List<String>> cues = ValueNotifier(const []);

  /// Les sous-titres image, peints par [SubtitleBitmapOverlay].
  final ValueNotifier<List<OnyxAppleSubtitleBitmap>> bitmaps =
      ValueNotifier(const []);

  final ValueNotifier<({EdgeInsets padding, Duration duration})>
      subtitleInset = ValueNotifier((
    padding: SubtitleOverlay.defaultPadding,
    duration: Duration.zero,
  ));

  /// N'émet que ce qui a changé : le natif envoie un instantané complet quatre
  /// fois par seconde, et les flux du port sont par propriété.
  void _onStatus(OnyxApplePlayerStatus status) {
    _status = status;
    _tracksNow = AetherTracks.of(status);
    _reportFailure(status);

    final position = Duration(milliseconds: status.positionMs);
    if (position != _lastPosition) {
      _lastPosition = position;
      _positions.add(position);
    }

    final duration = Duration(milliseconds: status.durationMs);
    if (duration != _nativeDuration) {
      _nativeDuration = duration;
      if (_durationOverride == null) _durations.add(duration);
    }

    if (status.isPlaying != _lastPlaying) {
      _lastPlaying = status.isPlaying;
      _playing.add(status.isPlaying);
      unawaited(ScreenAwake.set(status.isPlaying));
    }

    final buffering = status.state == OnyxApplePlaybackState.buffering;
    if (buffering != _lastBuffering) {
      _lastBuffering = buffering;
      _buffering.add(buffering);
    }

    final ended = status.state == OnyxApplePlaybackState.ended;
    if (ended && !_lastEnded) _completions.add(null);
    _lastEnded = ended;

    final trackCount = status.audioTracks.length + status.subtitleTracks.length;
    if (trackCount != _lastTrackCount) {
      _lastTrackCount = trackCount;
      _tracks.add(null);
    }

    final params = _paramsOf(status);
    if (params.width != _params.value.width ||
        params.height != _params.value.height ||
        params.aspect != _params.value.aspect) {
      _params.value = params;
      _videoParams.add(params);
    }
  }

  /// Le rapport d'image tient compte des pixels non carrés : un DVD 720×576
  /// anamorphosé est un 16/9, pas un 5/4.
  static PlaybackVideoParams _paramsOf(OnyxApplePlayerStatus status) {
    final size = status.videoSize;
    if (size == null || size.height <= 0) return PlaybackVideoParams.unknown;
    final pixelAspect = status.pixelAspectRatio ?? 1;
    return PlaybackVideoParams(
      width: size.width,
      height: size.height,
      aspect: size.width * pixelAspect / size.height,
    );
  }

  void _onSubtitles(OnyxAppleSubtitleFrame frame) {
    cues.value = List<String>.unmodifiable(frame.lines);
    bitmaps.value = List.unmodifiable(frame.bitmaps);
  }

  /// Traduit la panne du natif, et ne la dit qu'une fois : elle reste dans
  /// chaque instantané tant qu'elle tient, et le repli en transcodage serait
  /// sinon relancé à chaque fois.
  void _reportFailure(OnyxApplePlayerStatus status) {
    final kind = status.errorKind;
    if (kind == null) {
      _lastFailure = null;
      return;
    }
    final failure = PlaybackFailure(
      switch (kind) {
        OnyxApplePlayerErrorKind.unsupported => PlaybackFailureKind.unsupported,
        OnyxApplePlayerErrorKind.source => PlaybackFailureKind.source,
        OnyxApplePlayerErrorKind.unknown => PlaybackFailureKind.unknown,
      },
      status.errorMessage ?? kind.name,
    );
    if (failure == _lastFailure) return;
    _lastFailure = failure;
    ClientLog.error('AetherEngine: $failure');
    _failures.add(failure);
  }

  // --- Surface -----------------------------------------------------------

  @override
  Widget buildSurface({Key? key, required BoxFit fit, double? aspectRatio}) {
    return _AetherSurface(
      key: key,
      ready: _ready,
      session: this,
      fit: fit,
      aspectRatio: aspectRatio,
    );
  }

  @override
  void setSubtitlePadding(EdgeInsets padding,
      {Duration duration = Duration.zero}) {
    subtitleInset.value = (padding: padding, duration: duration);
  }

  // --- Commandes ---------------------------------------------------------

  Future<void> _run(Future<void> Function(OnyxApplePlayer) action) async {
    await action(await _ready);
  }

  @override
  Future<void> prepare() async {
    // Chaque session a son propre lecteur natif : rien n'est en train de
    // décharger un film précédent.
    await _ready;
  }

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) {
    _durationOverride = null;
    return _run(
      (p) => p.open(url, startPosition: start ?? Duration.zero, play: play),
    );
  }

  @override
  Future<void> play() => _run((p) => p.play());

  @override
  Future<void> pause() => _run((p) => p.pause());

  @override
  Future<void> seek(Duration position) => _run((p) => p.seekTo(position));

  @override
  Future<void> setVolume(double volume) {
    _volume = volume;
    return _run((p) => p.setVolume((volume / 100).clamp(0.0, 1.0)));
  }

  @override
  Future<void> setRate(double rate) => _run((p) => p.setRate(rate));

  @override
  Future<void> setAudioTrack(PlaybackTrack track) =>
      _run((p) => p.selectAudioTrack(track.id));

  @override
  Future<void> setSubtitles(SubtitleSelection selection) async {
    final p = await _ready;
    switch (selection) {
      case SubtitleNone():
        // Les deux : une piste du fichier et un WebVTT du serveur se posent
        // séparément, et n'en retirer qu'un laisserait l'autre à l'écran.
        await p.setExternalSubtitle(null);
        await p.selectSubtitleTrack(null);
      case SubtitleFromTrack(:final track):
        final nativeId = _tracksNow.nativeSubtitleId(track);
        if (nativeId == null) {
          debugPrint('AetherEngine: piste de sous-titres $track inconnue');
          return;
        }
        await p.selectSubtitleTrack(nativeId);
      case SubtitleFromVtt(:final content, :final title, :final language):
        await p.setExternalSubtitle(content, language: language, title: title);
    }
  }

  @override
  Future<void> stop() async {
    unawaited(ScreenAwake.set(false));
    await _run((p) => p.stop());
  }

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => _status?.isPlaying ?? false;

  @override
  bool get isBuffering => _status?.state == OnyxApplePlaybackState.buffering;

  @override
  Duration get position => _lastPosition;

  @override
  Duration get duration => _durationOverride ?? _nativeDuration;

  @override
  Duration get bufferedAhead {
    final status = _status;
    if (status == null) return Duration.zero;
    final ahead = status.bufferedPositionMs - status.positionMs;
    return Duration(milliseconds: ahead > 0 ? ahead : 0);
  }

  @override
  double get volume => _volume;

  @override
  PlaybackVideoParams get videoParams => _params.value;

  @override
  List<PlaybackTrack> get audioTracks => _tracksNow.audio;

  @override
  List<PlaybackTrack> get subtitleTracks => _tracksNow.subtitles;

  @override
  PlaybackTrack? get currentAudioTrack => _tracksNow.currentAudio;

  @override
  PlaybackTrack? get currentSubtitleTrack => _tracksNow.currentSubtitle;

  // --- Flux --------------------------------------------------------------

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<Duration> get durations => _durations.stream;

  @override
  Stream<bool> get playingChanges => _playing.stream;

  @override
  Stream<bool> get bufferingChanges => _buffering.stream;

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Stream<void> get trackChanges => _tracks.stream;

  @override
  Stream<PlaybackVideoParams> get videoParamChanges => _videoParams.stream;

  @override
  Stream<PlaybackFailure> get failures => _failures.stream;

  // --- Réglages ----------------------------------------------------------

  /// AetherEngine règle ses tampons seul : son cache de segments sur disque
  /// et la réserve d'AVPlayer n'ont pas d'équivalent aux octets et secondes
  /// que les profils règlent pour mpv.
  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) async {}

  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile) async {}

  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) =>
      _run((p) => p.setPreferredAudioLanguages(priorities));

  /// AVPlayer cherche toujours à l'image près ; rien à régler.
  @override
  Future<void> setExactSeek(bool exact) async {}

  /// Une session HLS qui grandit encore se dit plus courte qu'elle n'est :
  /// le contrôleur impose la vraie durée.
  @override
  Future<void> overrideDuration(Duration total) async {
    _durationOverride = total;
    _durations.add(total);
  }

  @override
  Future<void> onPictureLive() async {}

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    final stats = await (await _ready).stats();
    return PlaybackDiagnostics(
      videoCodec: stats.videoCodec,
      // Le chemin d'abord : `loopback` (AVPlayer) et `software` (FFmpeg) ne
      // chauffent pas du tout pareil, et c'est la première question devant
      // une lecture qui saccade.
      hardwareDecoder:
          '${stats.route ?? '?'} · ${stats.videoDecoder ?? 'aetherengine'}',
      containerFps: stats.containerFps,
      estimatedFps: stats.observedFps,
      droppedByDisplay: stats.droppedFrames,
      videoBitrate: stats.videoBitrate?.toDouble(),
      audioCodec: [stats.audioDecoder, stats.audioDelivery]
          .whereType<String>()
          .join(' · '),
    );
  }

  @override
  Future<void> dispose() async {
    unawaited(ScreenAwake.set(false));
    await _statusSubscription?.cancel();
    await _subtitleSubscription?.cancel();
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _buffering.close();
    await _completions.close();
    await _tracks.close();
    await _videoParams.close();
    await _failures.close();
    _params.dispose();
    cues.dispose();
    bitmaps.dispose();
    subtitleInset.dispose();
    await (await _ready).release();
  }
}

/// La vue native, cadrée, avec les sous-titres par-dessus.
///
/// Un widget à état plutôt qu'un `FutureBuilder` posé à l'appel : la vue de
/// plateforme est chère à construire, et l'écran se reconstruit à chaque
/// seconde de lecture.
class _AetherSurface extends StatefulWidget {
  const _AetherSurface({
    super.key,
    required this.ready,
    required this.session,
    required this.fit,
    this.aspectRatio,
  });

  final Future<OnyxApplePlayer> ready;
  final AetherPlaybackSession session;
  final BoxFit fit;
  final double? aspectRatio;

  @override
  State<_AetherSurface> createState() => _AetherSurfaceState();
}

class _AetherSurfaceState extends State<_AetherSurface> {
  int? _playerId;

  @override
  void initState() {
    super.initState();
    widget.ready.then((player) {
      if (mounted) setState(() => _playerId = player.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = _playerId;
    final session = widget.session;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Noir tant que la vue n'existe pas : l'écran du lecteur pose son
        // propre cache par-dessus jusqu'à la première image.
        const ColoredBox(color: Color(0xFF000000)),
        if (id != null)
          ValueListenableBuilder<PlaybackVideoParams>(
            valueListenable: session._params,
            builder: (context, params, _) => NativeVideoFraming(
              fit: widget.fit,
              aspectRatio: widget.aspectRatio ?? params.aspect ?? 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  OnyxApplePlayerView(playerId: id),
                  SubtitleBitmapOverlay(bitmaps: session.bitmaps),
                ],
              ),
            ),
          ),
        SubtitleOverlay(cues: session.cues, inset: session.subtitleInset),
      ],
    );
  }
}
