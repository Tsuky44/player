import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:onyx_player_android/onyx_player_android.dart';

import '../playback_profile.dart';
import 'playback_session.dart';
import 'subtitle_overlay.dart';

/// [PlaybackSession] adossée à ExoPlayer, sur Android.
///
/// Ce qui la distingue de la session mpv tient en une ligne : l'image va dans
/// une `SurfaceView` que le plan vidéo de l'écran compose, sans traverser le
/// GPU ni la scène Flutter. C'est ce que fait un lecteur de salon, et c'est ce
/// qui rend le 4K tenable sur une boîte de salon.
///
/// Tout le reste — reprise, sessions HLS, heartbeat, pistes, préférences —
/// appartient au contrôleur partagé, et cette classe n'en sait rien.
class ExoPlaybackSession implements PlaybackSession {
  /// Construite tout de suite, prête un peu après.
  ///
  /// Créer le lecteur natif demande un aller-retour, alors que le contrôleur
  /// construit sa session dans son constructeur — et que l'écran appelle
  /// [buildSurface] avant que quoi que ce soit ne soit chargé. Plutôt que de
  /// rendre le contrôleur asynchrone et d'avoir à protéger chaque accès, la
  /// session existe immédiatement et fait la queue derrière [_ready].
  ExoPlaybackSession() {
    _ready = OnyxPlayer.create().then((player) {
      _subscription = player.statuses.listen(_onStatus);
      return player;
    });
  }

  late final Future<OnyxPlayer> _ready;
  StreamSubscription<OnyxPlayerStatus>? _subscription;

  /// Le dernier état reçu du natif.
  ///
  /// ExoPlayer ne répond pas à des questions ponctuelles depuis Dart sans un
  /// aller-retour ; le port, lui, expose des accesseurs synchrones. On garde
  /// donc l'état, et les événements le tiennent à jour.
  OnyxPlayerStatus? _status;

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _tracks = StreamController<void>.broadcast();
  final _videoParams = StreamController<PlaybackVideoParams>.broadcast();

  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _lastEnded = false;
  int _lastTrackCount = -1;
  PlaybackVideoParams _lastParams = PlaybackVideoParams.unknown;

  /// N'émet que ce qui a changé.
  ///
  /// Le natif envoie un instantané complet à chaque événement — un seul objet à
  /// réconcilier, deux champs qui ne peuvent pas se contredire en chemin. Le
  /// prix est ici : les flux du port sont par propriété, et republier une
  /// position identique quatre fois par seconde ferait reconstruire tout
  /// l'habillage pour rien.
  void _onStatus(OnyxPlayerStatus status) {
    _status = status;

    final position = Duration(milliseconds: status.positionMs);
    if (position != _lastPosition) {
      _lastPosition = position;
      _positions.add(position);
    }

    final duration = Duration(milliseconds: status.durationMs);
    if (duration != _lastDuration) {
      _lastDuration = duration;
      _durations.add(duration);
    }

    if (status.isPlaying != _lastPlaying) {
      _lastPlaying = status.isPlaying;
      _playing.add(status.isPlaying);
    }

    final buffering = status.state == OnyxPlaybackState.buffering;
    if (buffering != _lastBuffering) {
      _lastBuffering = buffering;
      _buffering.add(buffering);
    }

    final ended = status.state == OnyxPlaybackState.ended;
    if (ended && !_lastEnded) _completions.add(null);
    _lastEnded = ended;

    final trackCount = status.audioTracks.length + status.subtitleTracks.length;
    if (trackCount != _lastTrackCount) {
      _lastTrackCount = trackCount;
      _tracks.add(null);
    }

    final size = status.videoSize;
    final params = size == null
        ? PlaybackVideoParams.unknown
        : PlaybackVideoParams(
            width: size.width,
            height: size.height,
            aspect: size.height > 0 ? size.width / size.height : null,
          );
    if (params.width != _lastParams.width ||
        params.height != _lastParams.height) {
      _lastParams = params;
      _videoParams.add(params);
    }

    // Republier des lignes identiques ferait reconstruire l'incrustation
    // quatre fois par seconde, pour rien.
    if (!_sameLines(status.subtitleCues, cues.value)) {
      cues.value = List<String>.unmodifiable(status.subtitleCues);
    }
  }

  @override
  Widget buildSurface({Key? key, required BoxFit fit, double? aspectRatio}) {
    // Le cadrage ne peut pas être posé par un widget parent : une SurfaceView
    // est une couche du système, pas un pixel de la scène. Il descend donc au
    // natif, où la vue se redimensionne elle-même.
    return _ExoSurface(key: key, ready: _ready, session: this, fit: fit);
  }

  /// Pousse le cadrage au natif. Appelé par la surface, qui sait quand il
  /// change.
  Future<void> _pushFit(BoxFit fit) => _run(
        (p) => p.setVideoFit(
          fit == BoxFit.cover ? OnyxVideoFit.cover : OnyxVideoFit.contain,
        ),
      );

  @override
  void setSubtitlePadding(EdgeInsets padding, {Duration duration = Duration.zero}) {
    subtitleInset.value = (padding: padding, duration: duration);
  }

  // --- Commandes ---------------------------------------------------------

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) {
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
    // Retenu : le natif ne le relit pas, et le port expose un accesseur
    // synchrone.
    _volume = volume;
    return _run((p) => p.setVolume(volume));
  }

  @override
  Future<void> setRate(double rate) => _run((p) => p.setRate(rate));

  @override
  Future<void> setAudioTrack(PlaybackTrack track) =>
      _run((p) => p.selectAudioTrack(track.id));

  @override
  Future<void> setSubtitles(SubtitleSelection selection) async {
    final p = await _ready;
    return switch (selection) {
      // Couper les deux : une piste interne et un fichier externe peuvent être
      // posés séparément, et n'en retirer qu'un laisserait l'autre à l'écran.
      // Couper les deux : une piste interne et un fichier externe peuvent être
      // posés séparément, et n'en retirer qu'un laisserait l'autre à l'écran.
      SubtitleNone() => Future.wait([
          p.selectSubtitleTrack(null),
          p.setExternalSubtitle(null),
        ]),
      SubtitleFromTrack(:final track) => p.selectSubtitleTrack(track.id),
      SubtitleFromVtt(:final content, :final title, :final language) =>
        p.setExternalSubtitle(content, language: language, title: title),
    };
  }

  /// Fait la queue derrière la création du lecteur natif.
  Future<void> _run(Future<void> Function(OnyxPlayer) action) async {
    action(await _ready);
  }

  @override
  Future<void> stop() async {
    // Surtout pas `setExternalSubtitle(null)` : retirer un sous-titre externe
    // fait rouvrir le média, ce qui est l'inverse de l'arrêter. Le natif oublie
    // les deux d'un coup.
    await (await _ready).stop();
  }

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => _status?.isPlaying ?? false;

  @override
  bool get isBuffering => _status?.state == OnyxPlaybackState.buffering;

  @override
  Duration get position => _lastPosition;

  @override
  Duration get duration => _lastDuration;

  @override
  Duration get bufferedAhead {
    final status = _status;
    if (status == null) return Duration.zero;
    final ahead = status.bufferedPositionMs - status.positionMs;
    return Duration(milliseconds: ahead > 0 ? ahead : 0);
  }

  /// ExoPlayer travaille en 0..1 ; le reste de l'app parle en 0..100, comme
  /// mpv. La conversion vit dans le plugin ; ce que l'app a demandé est retenu
  /// ici, faute d'être relu du natif.
  double _volume = 100;

  @override
  double get volume => _volume;

  @override
  PlaybackVideoParams get videoParams => _lastParams;

  @override
  List<PlaybackTrack> get audioTracks =>
      _status?.audioTracks.map(_toTrack).toList() ?? const [];

  @override
  List<PlaybackTrack> get subtitleTracks =>
      _status?.subtitleTracks.map(_toTrack).toList() ?? const [];

  @override
  PlaybackTrack? get currentAudioTrack =>
      _find(_status?.audioTracks, _status?.selectedAudioTrackId);

  @override
  PlaybackTrack? get currentSubtitleTrack =>
      _find(_status?.subtitleTracks, _status?.selectedSubtitleTrackId);

  /// Les lignes de sous-titre à afficher maintenant.
  ///
  /// mpv les dessine lui-même dans une vue que media_kit fournit ; ExoPlayer
  /// les remonte en texte et c'est [buildSurface] qui les peint, avec le même
  /// habillage que les autres plateformes.
  final ValueNotifier<List<String>> cues = ValueNotifier(const []);

  /// De combien remonter les sous-titres, pour qu'ils passent au-dessus de la
  /// barre de progression quand elle est là.
  final ValueNotifier<({EdgeInsets padding, Duration duration})>
      subtitleInset = ValueNotifier((
    padding: SubtitleOverlay.defaultPadding,
    duration: Duration.zero,
  ));

  static bool _sameLines(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static PlaybackTrack _toTrack(OnyxTrack t) =>
      PlaybackTrack(id: t.id, title: t.title, language: t.language);

  static PlaybackTrack? _find(List<OnyxTrack>? tracks, String? id) {
    if (tracks == null || id == null) return null;
    for (final t in tracks) {
      if (t.id == id) return _toTrack(t);
    }
    return null;
  }

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

  // --- Réglages ----------------------------------------------------------

  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) =>
      _run((p) => p.setPreferredAudioLanguages(priorities));

  @override
  Future<void> setExactSeek(bool exact) => _run((p) => p.setExactSeek(exact));

  @override
  Future<void> overrideDuration(Duration total) =>
      _run((p) => p.overrideDuration(total));

  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) =>
      _run((p) => p.applyTuning(_tuningFor(profile, streaming: false)));

  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile) =>
      _run((p) => p.applyTuning(_tuningFor(profile, streaming: true)));

  /// Traduit un profil — écrit dans le vocabulaire de mpv, en octets et en
  /// secondes — vers les millisecondes de `DefaultLoadControl`.
  ///
  /// Les secondes de lecture d'avance se transposent directement ; les octets
  /// de tampon arrière n'ont pas d'équivalent, et ce qu'ils achetaient est un
  /// retour de dix secondes qui ne repasse pas par le réseau. C'est cette
  /// intention-là qu'on porte, pas le nombre.
  static OnyxLoadTuning _tuningFor(
    PlaybackProfile profile, {
    required bool streaming,
  }) {
    final readahead =
        streaming ? profile.hlsReadaheadSecs : profile.readaheadSecs;
    return OnyxLoadTuning(
      // La moitié de la cible : en dessous, ExoPlayer se remet à charger.
      minBufferMs: (readahead * 500).round(),
      maxBufferMs: readahead * 1000,
      // Court, et c'est délibéré : c'est du temps ajouté devant la première
      // image à chaque ouverture. mpv posait `cache-pause-initial=no` pour la
      // même raison.
      bufferForPlaybackMs: 1000,
      backBufferMs: 15000,
    );
  }

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    final stats = await (await _ready).stats();
    final status = _status;
    return PlaybackDiagnostics(
      // ExoPlayer ne passe que par MediaCodec : il n'y a pas de repli logiciel
      // silencieux à débusquer, contrairement à mpv.
      hardwareDecoder: 'mediacodec',
      droppedByDisplay: stats.droppedFrames,
      audioCodec: status?.selectedAudioTrackId,
    );
  }

  @override
  Future<void> onPictureLive() async {
    // Rien à rattraper : le décodeur matériel est le seul chemin.
  }

  @override
  Future<void> prepare() async {
    // Rien à attendre : chaque session a son propre lecteur natif, il n'y a pas
    // d'instance recyclée qui pourrait être en train de décharger un film.
    await _ready;
  }

  /// Détruit le lecteur natif. Sans appel, ExoPlayer garde son décodeur, sa
  /// connexion et son audio — le film continue de s'entendre après qu'on l'a
  /// quitté.
  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _positions.close();
    await _durations.close();
    await _playing.close();
    await _buffering.close();
    await _completions.close();
    await _tracks.close();
    await _videoParams.close();
    cues.dispose();
    subtitleInset.dispose();
    await (await _ready).release();
  }
}

/// La surface, une fois le lecteur natif créé.
///
/// Un widget plutôt qu'un `FutureBuilder` posé à l'appel : la vue de plateforme
/// est chère à construire, et un `FutureBuilder` la reconstruirait à chaque
/// rebuild de l'écran — c'est-à-dire à chaque seconde de lecture.
class _ExoSurface extends StatefulWidget {
  const _ExoSurface({
    super.key,
    required this.ready,
    required this.session,
    required this.fit,
  });

  final Future<OnyxPlayer> ready;
  final ExoPlaybackSession session;
  final BoxFit fit;

  @override
  State<_ExoSurface> createState() => _ExoSurfaceState();
}

class _ExoSurfaceState extends State<_ExoSurface> {
  int? _playerId;

  @override
  void initState() {
    super.initState();
    widget.ready.then((player) {
      if (!mounted) return;
      setState(() => _playerId = player.id);
      widget.session._pushFit(widget.fit);
    });
  }

  @override
  void didUpdateWidget(_ExoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Le pincement et le réglage « taille adaptative » passent par ici : ils
    // reconstruisent la surface avec un autre cadrage, qu'il faut porter au
    // natif — un `BoxFit` seul n'atteindrait pas la couche vidéo.
    if (widget.fit != oldWidget.fit && _playerId != null) {
      widget.session._pushFit(widget.fit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _playerId;
    // Noir plutôt que rien : l'écran du lecteur pose son propre cache et son
    // indicateur par-dessus tant que la première image n'est pas arrivée.
    if (id == null) return const ColoredBox(color: Color(0xFF000000));
    return Stack(
      fit: StackFit.expand,
      children: [
        OnyxPlayerView(playerId: id),
        // Au-dessus de la SurfaceView, pas dedans : Flutter compose son
        // interface par-dessus la couche vidéo, ce qui est justement ce que la
        // composition hybride permet.
        SubtitleOverlay(
          cues: widget.session.cues,
          inset: widget.session.subtitleInset,
        ),
      ],
    );
  }
}
