import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../services/client_log.dart';
import '../../../utils/app_platform.dart';
import '../playback_profile.dart';
import 'playback_session.dart';
import 'subtitle_overlay.dart';
import 'vtt_cues.dart';

/// [PlaybackSession] adossée à AVPlayer : sur l'Apple TV, et sur iPhone et Mac
/// pour les fichiers que le serveur recopie (ADR-0035).
///
/// Ni mpv ni ExoPlayer n'existent sur tvOS : c'est le lecteur du système, par
/// le portage tvOS de `video_player` (`video_player_tvos`). On lui parle par
/// l'interface de plateforme, sans le paquet `video_player` et son contrôleur :
/// le contrôleur de l'app fait déjà tout ce que celui-là ferait, et le paquet
/// ajouterait un ExoPlayer au build Android.
///
/// AVPlayer ne lit pas le MKV. L'Apple TV ne fait donc jamais de Direct Play :
/// le contrôleur ouvre toujours une session HLS (voir `hlsOnly` dans
/// `use_player_controller.dart`), que le serveur remplit en recopiant les
/// pistes quand elles tiennent dans un segment fMP4.
///
/// L'API du port est plus pauvre que celles de mpv et d'ExoPlayer — pas de
/// flux de position, pas de sous-titres externes, pas de réglage de tampon.
/// Ce qui manque est reconstruit ici : la position est relue quatre fois par
/// seconde, et le WebVTT du serveur est découpé puis peint par
/// [SubtitleOverlay], comme sur Android.
class AvPlayerPlaybackSession implements PlaybackSession {
  AvPlayerPlaybackSession({this.viewType = VideoViewType.textureView});

  /// Comment l'image arrive à l'écran.
  ///
  /// La texture est le seul chemin que le portage tvOS a vérifié sur une vraie
  /// Apple TV, mais elle recopie chaque image en BGRA 8 bits : le HDR y est
  /// perdu, et la copie coûte. Sur iPhone et Mac, la vue native
  /// (`AVPlayerLayer`) pose l'image décodée telle quelle dans la couche
  /// d'affichage — le chemin le plus économe, et le seul qui garde le HDR.
  final VideoViewType viewType;

  static VideoPlayerPlatform get _platform => VideoPlayerPlatform.instance;

  /// Le canal de l'hôte tvOS (`tvos/Runner/AppDelegate.swift`).
  static const MethodChannel _device = MethodChannel('onyx/device');

  /// `init()` vide la table des lecteurs natifs : une fois par processus, pas
  /// une fois par film.
  static Future<void>? _platformReady;

  /// Le lecteur natif en cours, ou null entre deux films. Un lecteur AVPlayer
  /// naît avec son URL : chaque [open] en crée un neuf, et la surface suit.
  final ValueNotifier<int?> _playerId = ValueNotifier<int?>(null);
  StreamSubscription<VideoEvent>? _events;
  Timer? _clock;

  /// Chaque ouverture porte un numéro : les événements d'un lecteur qu'on
  /// vient de remplacer ne doivent rien écrire dans l'état du suivant.
  int _generation = 0;

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _tracks = StreamController<void>.broadcast();
  final _videoParams = StreamController<PlaybackVideoParams>.broadcast();
  final _failures = StreamController<PlaybackFailure>.broadcast();

  bool _disposed = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _initialized = false;
  Duration _position = Duration.zero;
  Duration _nativeDuration = Duration.zero;
  Duration? _durationOverride;
  Duration _bufferedEnd = Duration.zero;
  double _volume = 100;
  double _rate = 1;
  final ValueNotifier<PlaybackVideoParams> _params =
      ValueNotifier(PlaybackVideoParams.unknown);
  List<VideoAudioTrack> _audio = const [];

  /// Ce qu'on a demandé avant que le lecteur soit prêt : AVPlayer n'accepte
  /// ni lecture ni recherche avant `initialized`.
  Duration? _pendingStart;
  bool _playWhenReady = false;

  VttCues _subtitle = VttCues.empty;

  /// Les lignes à afficher maintenant, que [SubtitleOverlay] peint.
  final ValueNotifier<List<String>> cues = ValueNotifier(const []);

  final ValueNotifier<({EdgeInsets padding, Duration duration})> subtitleInset =
      ValueNotifier((
    padding: SubtitleOverlay.defaultPadding,
    duration: Duration.zero,
  ));

  // --- Surface -----------------------------------------------------------

  @override
  Widget buildSurface({Key? key, required BoxFit fit, double? aspectRatio}) {
    return _AvPlayerSurface(
      key: key,
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

  @override
  Future<void> prepare() => _platformReady ??= _platform.init();

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) async {
    await prepare();
    await _release();
    if (_disposed) return;

    final generation = ++_generation;
    _initialized = false;
    _pendingStart = (start != null && start > Duration.zero) ? start : null;
    _playWhenReady = play;
    _setPosition(start ?? Duration.zero);
    _nativeDuration = Duration.zero;
    _bufferedEnd = Duration.zero;
    _audio = const [];
    _setBuffering(true);

    final int? id;
    try {
      id = await _platform.createWithOptions(
        VideoCreationOptions(
          dataSource: DataSource(
            sourceType: DataSourceType.network,
            uri: url,
            // L'URL de session porte déjà son ticket d'accès.
            formatHint: url.contains('.m3u8') ? VideoFormat.hls : null,
          ),
          // Texture sur l'Apple TV, en BGRA 8 bits, d'où `hdr: false` dans
          // `PlaybackCapabilities.appleTv`. Voir [viewType].
          viewType: viewType,
        ),
      );
    } catch (error) {
      _fail(PlaybackFailureKind.source, '$error');
      return;
    }
    if (id == null) {
      _fail(PlaybackFailureKind.unknown, 'AVPlayer: création refusée');
      return;
    }
    if (_disposed || generation != _generation) {
      unawaited(_platform.dispose(id));
      return;
    }

    _events = _platform.videoEventsFor(id).listen(
          (event) => _onEvent(generation, id!, event),
          onError: (Object error) => _onError(generation, error),
        );
    _playerId.value = id;
  }

  @override
  Future<void> play() async {
    final id = _playerId.value;
    if (id == null || !_initialized) {
      _playWhenReady = true;
      return;
    }
    await _platform.play(id);
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    _playWhenReady = false;
    final id = _playerId.value;
    if (id == null || !_initialized) return;
    await _platform.pause(id);
    _setPlaying(false);
  }

  @override
  Future<void> seek(Duration position) async {
    final id = _playerId.value;
    if (id == null || !_initialized) {
      _pendingStart = position;
      _setPosition(position);
      return;
    }
    _setPosition(position);
    await _platform.seekTo(id, position);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    final id = _playerId.value;
    if (id == null) return;
    await _platform.setVolume(id, (volume / 100).clamp(0.0, 1.0));
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    final id = _playerId.value;
    if (id == null || !_initialized) return;
    await _platform.setPlaybackSpeed(id, rate);
  }

  @override
  Future<void> setAudioTrack(PlaybackTrack track) async {
    final id = _playerId.value;
    if (id == null || !_initialized) return;
    await _platform.selectAudioTrack(id, track.id);
    await _refreshAudioTracks(id);
  }

  @override
  Future<void> setSubtitles(SubtitleSelection selection) async {
    _subtitle = switch (selection) {
      SubtitleFromVtt(:final content) => VttCues.parse(content),
      // Pas de pistes internes ici : le HLS du serveur n'en porte pas, les
      // sous-titres arrivent toujours en WebVTT à part.
      SubtitleFromTrack() || SubtitleNone() => VttCues.empty,
    };
    _updateCues();
  }

  @override
  Future<void> stop() async {
    _playWhenReady = false;
    await _release();
    _setPlaying(false);
    _setBuffering(false);
  }

  // --- Événements --------------------------------------------------------

  void _onEvent(int generation, int id, VideoEvent event) {
    if (_disposed || generation != _generation) return;
    switch (event.eventType) {
      case VideoEventType.initialized:
        unawaited(_onInitialized(generation, id, event));
      case VideoEventType.completed:
        _setPlaying(false);
        _completions.add(null);
      case VideoEventType.bufferingUpdate:
        final ranges = event.buffered ?? const <DurationRange>[];
        _bufferedEnd = ranges.isEmpty
            ? Duration.zero
            : ranges.map((r) => r.end).reduce((a, b) => a > b ? a : b);
      case VideoEventType.bufferingStart:
        _setBuffering(true);
      case VideoEventType.bufferingEnd:
        _setBuffering(false);
      case VideoEventType.isPlayingStateUpdate:
        _setPlaying(event.isPlaying ?? false);
      case VideoEventType.unknown:
        break;
    }
  }

  Future<void> _onInitialized(int generation, int id, VideoEvent event) async {
    _initialized = true;

    final duration = event.duration ?? Duration.zero;
    // Une session qui grandit encore se dit « indéfinie » : AVFoundation la
    // rapporte comme une durée nulle ou absurde. Le contrôleur impose alors la
    // vraie durée par [overrideDuration].
    if (duration > Duration.zero && duration < const Duration(days: 2)) {
      _nativeDuration = duration;
      if (_durationOverride == null) _durations.add(duration);
    }

    final size = event.size;
    if (size != null && size.width > 0 && size.height > 0) {
      _params.value = PlaybackVideoParams(
        width: size.width.round(),
        height: size.height.round(),
        aspect: size.width / size.height,
      );
      _videoParams.add(_params.value);
    }

    await _platform.setVolume(id, (_volume / 100).clamp(0.0, 1.0));
    if (_rate != 1) await _platform.setPlaybackSpeed(id, _rate);
    final start = _pendingStart;
    _pendingStart = null;
    if (start != null) await _platform.seekTo(id, start);
    if (_disposed || generation != _generation) return;

    _startClock(generation, id);
    await _refreshAudioTracks(id);
    if (_playWhenReady) {
      await _platform.play(id);
      _setPlaying(true);
    }
  }

  void _onError(int generation, Object error) {
    if (_disposed || generation != _generation) return;
    final message = error is PlatformException
        ? '${error.code}: ${error.message ?? ''}'
        : '$error';
    _fail(_classify(message), message);
  }

  /// Ce qu'AVFoundation dit de sa panne, ramené aux trois cas du contrôleur.
  ///
  /// Les codes sont ceux d'`AVError` et de `NSURLError` : -11828/-11829 et
  /// consorts pour un format refusé, la famille -1xxx et -12938 (404 sur un
  /// segment) pour une source injoignable.
  static PlaybackFailureKind _classify(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('-11828') ||
        lower.contains('-11829') ||
        lower.contains('-11821') ||
        lower.contains('-12847') ||
        lower.contains('not supported') ||
        lower.contains('cannot open') ||
        lower.contains('unsupported')) {
      return PlaybackFailureKind.unsupported;
    }
    if (RegExp(r'-1\d{3}\b').hasMatch(lower) ||
        lower.contains('-12938') ||
        lower.contains('-12660') ||
        lower.contains('network') ||
        lower.contains('timed out') ||
        lower.contains('offline')) {
      return PlaybackFailureKind.source;
    }
    return PlaybackFailureKind.unknown;
  }

  void _fail(PlaybackFailureKind kind, String message) {
    final failure = PlaybackFailure(kind, message);
    ClientLog.error('AVPlayer: $failure');
    _setBuffering(false);
    _failures.add(failure);
  }

  /// La position, relue au rythme où la barre de progression en a besoin.
  ///
  /// Le port ne pousse pas la position : c'est aussi ce que fait le
  /// contrôleur de `video_player`, qui la relit toutes les 500 ms. 250 ms
  /// ici, parce que les sous-titres en dépendent.
  void _startClock(int generation, int id) {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_disposed || generation != _generation) return;
      if (!_isPlaying) return;
      try {
        final position = await _platform.getPosition(id);
        if (_disposed || generation != _generation) return;
        _setPosition(position);
      } catch (_) {
        // Un lecteur en train d'être rendu : la prochaine relecture dira.
      }
    });
  }

  Future<void> _refreshAudioTracks(int id) async {
    try {
      final tracks = await _platform.getAudioTracks(id);
      if (_playerId.value != id) return;
      _audio = tracks;
      _tracks.add(null);
    } catch (error) {
      debugPrint('AVPlayer: pistes audio illisibles ($error)');
    }
  }

  void _setPosition(Duration position) {
    if (position == _position) return;
    _position = position;
    _positions.add(position);
    _updateCues();
  }

  void _setPlaying(bool playing) {
    if (playing == _isPlaying) return;
    _isPlaying = playing;
    _playing.add(playing);
    if (playing) _setBuffering(false);
    // Ni l'économiseur d'écran de tvOS ni la mise en veille d'un iPhone ou d'un
    // Mac ne savent qu'une vue Flutter est un film : sans ça, l'écran s'éteint
    // au milieu de la lecture.
    unawaited(_keepScreenOn(playing));
  }

  void _setBuffering(bool buffering) {
    if (buffering == _isBuffering) return;
    _isBuffering = buffering;
    _buffering.add(buffering);
  }

  void _updateCues() {
    final lines =
        _subtitle.isEmpty ? const <String>[] : _subtitle.linesAt(_position);
    if (!_sameLines(lines, cues.value)) {
      cues.value = List<String>.unmodifiable(lines);
    }
  }

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<void> _keepScreenOn(bool on) async {
    try {
      // wakelock_plus n'a pas de portage tvOS : l'hôte le fait lui-même.
      if (AppPlatform.isTvOS) {
        await _device.invokeMethod<void>('setKeepScreenOn', on);
      } else {
        await WakelockPlus.toggle(enable: on);
      }
    } catch (_) {
      // Un hôte sans ce canal : l'écran s'éteindra, la lecture continuera.
    }
  }

  /// Rend le lecteur natif en cours, s'il y en a un.
  Future<void> _release() async {
    _generation++;
    _clock?.cancel();
    _clock = null;
    await _events?.cancel();
    _events = null;
    final id = _playerId.value;
    _playerId.value = null;
    _initialized = false;
    if (id != null) {
      try {
        await _platform.dispose(id);
      } catch (_) {}
    }
  }

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isBuffering => _isBuffering;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _durationOverride ?? _nativeDuration;

  @override
  Duration get bufferedAhead {
    final ahead = _bufferedEnd - _position;
    return ahead > Duration.zero ? ahead : Duration.zero;
  }

  @override
  double get volume => _volume;

  @override
  PlaybackVideoParams get videoParams => _params.value;

  @override
  List<PlaybackTrack> get audioTracks => _audio.map(_toTrack).toList();

  @override
  List<PlaybackTrack> get subtitleTracks => const [];

  @override
  PlaybackTrack? get currentAudioTrack {
    for (final track in _audio) {
      if (track.isSelected) return _toTrack(track);
    }
    return null;
  }

  @override
  PlaybackTrack? get currentSubtitleTrack => null;

  static PlaybackTrack _toTrack(VideoAudioTrack t) =>
      PlaybackTrack(id: t.id, title: t.label, language: t.language);

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

  /// AVPlayer choisit ses tampons seul, et bien : il n'expose rien de ce que
  /// les profils règlent pour mpv et ExoPlayer.
  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) async {}

  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile) async {}

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    return PlaybackDiagnostics(
      hardwareDecoder: 'avplayer',
      audioCodec: currentAudioTrack?.title,
    );
  }

  /// La session HLS publie les pistes dans l'ordre que le serveur a choisi, et
  /// le contrôleur sélectionne la bonne par [setAudioTrack] : il n'y a pas de
  /// préférence à poser d'avance.
  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) async {}

  @override
  Future<void> setExactSeek(bool exact) async {}

  @override
  Future<void> overrideDuration(Duration total) async {
    _durationOverride = total;
    _durations.add(total);
  }

  @override
  Future<void> onPictureLive() async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _release();
    unawaited(_keepScreenOn(false));
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _buffering.close();
    await _completions.close();
    await _tracks.close();
    await _videoParams.close();
    await _failures.close();
    _playerId.dispose();
    _params.dispose();
    cues.dispose();
    subtitleInset.dispose();
  }
}

/// La texture d'AVPlayer, cadrée, avec les sous-titres par-dessus.
class _AvPlayerSurface extends StatelessWidget {
  const _AvPlayerSurface({
    super.key,
    required this.session,
    required this.fit,
    this.aspectRatio,
  });

  final AvPlayerPlaybackSession session;
  final BoxFit fit;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF000000)),
        ListenableBuilder(
          listenable: Listenable.merge([session._playerId, session._params]),
          builder: (context, _) {
            // Noir tant qu'il n'y a pas de lecteur : l'écran du lecteur pose
            // son propre cache par-dessus jusqu'à la première image.
            final id = session._playerId.value;
            if (id == null) return const SizedBox.shrink();
            final ratio = aspectRatio ?? session.videoParams.aspect ?? 16 / 9;
            if (session.viewType == VideoViewType.platformView) {
              return _NativeFraming(
                fit: fit,
                aspectRatio: ratio,
                child: _platformView(id),
              );
            }
            // Une texture n'a pas de taille propre : on lui en donne une au
            // bon rapport, que FittedBox cadre comme `BoxFit` le demande.
            return FittedBox(
              fit: fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1920,
                height: 1920 / ratio,
                child: _platformView(id),
              ),
            );
          },
        ),
        SubtitleOverlay(cues: session.cues, inset: session.subtitleInset),
      ],
    );
  }

  static Widget _platformView(int id) =>
      VideoPlayerPlatform.instance.buildViewWithOptions(
        VideoViewOptions(playerId: id),
      );
}

/// Cadre une vue native par sa taille, sans transformation.
///
/// FittedBox met une texture à l'échelle ; une vue native, elle, ne suit une
/// mise à l'échelle que de façon inégale selon la plateforme (c'est aussi
/// pourquoi mpv reçoit son cadrage en options sur macOS). La vue reçoit donc
/// directement la taille que [fit] lui donne, centrée — et `AVPlayerLayer`,
/// qui garde le rapport de l'image, la remplit exactement.
class _NativeFraming extends StatelessWidget {
  const _NativeFraming({
    required this.fit,
    required this.aspectRatio,
    required this.child,
  });

  final BoxFit fit;
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final size = applyBoxFit(fit, Size(aspectRatio, 1), box).destination;
        return ClipRect(
          child: OverflowBox(
            maxWidth: size.width,
            maxHeight: size.height,
            child: SizedBox.fromSize(size: size, child: child),
          ),
        );
      },
    );
  }
}
