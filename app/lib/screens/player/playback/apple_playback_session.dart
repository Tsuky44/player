import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../playback_profile.dart';
import 'avplayer_playback_session.dart';
import 'mpv_playback_session.dart';
import 'playback_session.dart';

/// La session de l'iPhone et du Mac : AVPlayer quand le serveur recopie le
/// fichier en HLS, mpv pour tout le reste — voir l'ADR-0035.
///
/// AVPlayer est le lecteur qui chauffe le moins sur un appareil Apple, mais il
/// n'ouvre ni le MKV ni une bonne partie de ce qu'une médiathèque contient
/// (VP9, MPEG-2, VC-1, sous-titres image…). mpv, lui, lit tout en Direct Play
/// sans rien demander au serveur. Les deux restent donc disponibles, et le
/// contrôleur dit lequel prendre par [streamsOnAvPlayer] : une session HLS
/// s'ouvre alors dans AVPlayer, un fichier dans mpv.
///
/// Pour le contrôleur, c'est une session comme une autre. Les flux du moteur
/// qui ne joue pas sont ignorés, et la surface suit le moteur actif.
class ApplePlaybackSession implements PlaybackSession {
  ApplePlaybackSession() {
    _mpvSubscriptions = _forward(_mpv, () => _active == _mpv);
  }

  final MpvPlaybackSession _mpv = MpvPlaybackSession();

  /// Créé à la première session HLS qui lui revient : un film lu par mpv ne
  /// paie rien pour lui.
  AvPlayerPlaybackSession? _av;
  List<StreamSubscription<void>> _avSubscriptions = const [];
  late final List<StreamSubscription<void>> _mpvSubscriptions;

  /// Le moteur qui joue ; la surface le suit.
  late final ValueNotifier<PlaybackSession> _engine =
      ValueNotifier<PlaybackSession>(_mpv);
  PlaybackSession get _active => _engine.value;

  /// Les sessions HLS vont à AVPlayer. Posé par le contrôleur quand le fichier
  /// peut être recopié tel quel ([AvPlayerRemux]), retiré quand il repasse en
  /// Direct Play.
  bool streamsOnAvPlayer = false;

  /// AVPlayer lit en ce moment.
  bool get onAvPlayer => identical(_active, _av);

  AvPlayerPlaybackSession _avPlayer() {
    final existing = _av;
    if (existing != null) return existing;
    final av = AvPlayerPlaybackSession(viewType: VideoViewType.platformView);
    _av = av;
    _avSubscriptions = _forward(av, () => identical(_active, av));
    // Ce que l'utilisateur a réglé avant que ce moteur n'existe.
    unawaited(av.setVolume(_mpv.volume));
    if (_rate != 1) unawaited(av.setRate(_rate));
    return av;
  }

  double _rate = 1;

  List<StreamSubscription<void>> _forward(
    PlaybackSession engine,
    bool Function() isActive,
  ) {
    StreamSubscription<void> pipe<T>(
      Stream<T> source,
      StreamController<T> sink,
    ) =>
        source.listen((value) {
          if (isActive() && !sink.isClosed) sink.add(value);
        });
    return [
      pipe(engine.positions, _positions),
      pipe(engine.durations, _durations),
      pipe(engine.playingChanges, _playing),
      pipe(engine.bufferingChanges, _buffering),
      pipe(engine.completions, _completions),
      pipe(engine.trackChanges, _tracks),
      pipe(engine.videoParamChanges, _videoParams),
      pipe(engine.failures, _failures),
    ];
  }

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _tracks = StreamController<void>.broadcast();
  final _videoParams = StreamController<PlaybackVideoParams>.broadcast();
  final _failures = StreamController<PlaybackFailure>.broadcast();

  /// Passe la main à [next], en déchargeant l'autre : deux moteurs chargés,
  /// c'est deux connexions et deux décodeurs pour une seule image.
  Future<void> _switchTo(PlaybackSession next) async {
    if (identical(next, _active)) return;
    final previous = _active;
    _engine.value = next;
    try {
      await previous.stop();
    } catch (e) {
      debugPrint('Lecture : arrêt du moteur précédent impossible ($e)');
    }
  }

  // --- Surface -----------------------------------------------------------

  @override
  Widget buildSurface({Key? key, required BoxFit fit, double? aspectRatio}) {
    return ValueListenableBuilder<PlaybackSession>(
      key: key,
      valueListenable: _engine,
      builder: (context, engine, _) => KeyedSubtree(
        // Un moteur, une surface : la vue de l'un ne doit rien hériter de
        // l'état de l'autre.
        key: ObjectKey(engine),
        child: engine.buildSurface(fit: fit, aspectRatio: aspectRatio),
      ),
    );
  }

  @override
  void setSubtitlePadding(EdgeInsets padding,
      {Duration duration = Duration.zero}) {
    _mpv.setSubtitlePadding(padding, duration: duration);
    _av?.setSubtitlePadding(padding, duration: duration);
  }

  // --- Commandes ---------------------------------------------------------

  @override
  Future<void> prepare() => _mpv.prepare();

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) async {
    final engine = streamsOnAvPlayer && _isHlsSession(url) ? _avPlayer() : _mpv;
    await _switchTo(engine);
    await engine.open(url, start: start, play: play);
  }

  /// Une session du serveur, par opposition au fichier lui-même.
  static bool _isHlsSession(String url) =>
      Uri.tryParse(url)?.path.endsWith('.m3u8') ?? url.contains('.m3u8');

  @override
  Future<void> play() => _active.play();

  @override
  Future<void> pause() => _active.pause();

  @override
  Future<void> seek(Duration position) => _active.seek(position);

  @override
  Future<void> setVolume(double volume) async {
    await _mpv.setVolume(volume);
    await _av?.setVolume(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _mpv.setRate(rate);
    await _av?.setRate(rate);
  }

  @override
  Future<void> setAudioTrack(PlaybackTrack track) =>
      _active.setAudioTrack(track);

  @override
  Future<void> setSubtitles(SubtitleSelection selection) =>
      _active.setSubtitles(selection);

  @override
  Future<void> stop() => _active.stop();

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => _active.isPlaying;

  @override
  bool get isBuffering => _active.isBuffering;

  @override
  Duration get position => _active.position;

  @override
  Duration get duration => _active.duration;

  @override
  Duration get bufferedAhead => _active.bufferedAhead;

  @override
  double get volume => _active.volume;

  @override
  PlaybackVideoParams get videoParams => _active.videoParams;

  @override
  List<PlaybackTrack> get audioTracks => _active.audioTracks;

  @override
  List<PlaybackTrack> get subtitleTracks => _active.subtitleTracks;

  @override
  PlaybackTrack? get currentAudioTrack => _active.currentAudioTrack;

  @override
  PlaybackTrack? get currentSubtitleTrack => _active.currentSubtitleTrack;

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

  /// Le Direct Play est toujours celui de mpv, même appelé pendant qu'AVPlayer
  /// joue encore : le retour en Direct Play règle le moteur avant d'ouvrir.
  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) =>
      _mpv.applyDirectPlayTuning(profile);

  /// Réglé sur mpv, qui garde les sessions HLS que [streamsOnAvPlayer] ne lui
  /// prend pas. AVPlayer n'a rien à régler.
  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile) =>
      _mpv.applyStreamingTuning(profile);

  @override
  Future<PlaybackDiagnostics> readDiagnostics() => _active.readDiagnostics();

  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) =>
      _mpv.setPreferredAudioLanguages(priorities);

  @override
  Future<void> setExactSeek(bool exact) => _active.setExactSeek(exact);

  @override
  Future<void> overrideDuration(Duration total) =>
      _active.overrideDuration(total);

  @override
  Future<void> onPictureLive() => _active.onPictureLive();

  @override
  Future<void> dispose() async {
    for (final subscription in [..._mpvSubscriptions, ..._avSubscriptions]) {
      await subscription.cancel();
    }
    await _mpv.dispose();
    await _av?.dispose();
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _buffering.close();
    await _completions.close();
    await _tracks.close();
    await _videoParams.close();
    await _failures.close();
    _engine.dispose();
  }
}
