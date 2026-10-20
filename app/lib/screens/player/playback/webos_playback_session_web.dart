import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../playback_profile.dart';
import '../web/web_playback.dart';
import 'playback_session.dart';

PlaybackSession createWebOSPlaybackSession() => WebOSPlaybackSession();

/// [PlaybackSession] d'un téléviseur LG : un `<video>` à qui l'on donne le
/// fichier lui-même (ADR-0076).
///
/// Sur webOS, l'élément ne décode rien dans la page. Une source qu'il ouvre
/// par `src` part dans le pipeline multimédia du téléviseur — celui de son
/// lecteur USB, avec ses décodeurs matériels — et l'image est composée dans
/// le plan vidéo, sous la page. C'est ce qui permet le Direct Play d'un
/// Matroska HEVC 10 bits HDR10 avec sa piste E-AC-3, qu'aucun onglet de
/// bureau ne lit, et ce qui tient la 4K sans un cœur de processeur.
///
/// media_kit n'est pas utilisé ici : son backend web ne sait pas changer de
/// piste audio dans un fichier (`setAudioTrack` n'y accepte qu'une URI), et
/// un Matroska multilingue est le cas courant. `audioTracks` est en revanche
/// exposé par le moteur de webOS.
///
/// Le repli HLS passe par le même élément : hls.js y est chargé, et c'est le
/// contrôleur qui le met en charge par `WebPlayback.adoptHlsSession`, comme
/// sur tout le web — la passerelle trouve l'unique `<video>` de la page.
class WebOSPlaybackSession implements PlaybackSession {
  WebOSPlaybackSession() : _viewType = 'onyx-webos-video-${_nextView++}' {
    _video = web.HTMLVideoElement()
      ..preload = 'auto'
      ..autoplay = false
      ..setAttribute('playsinline', '');
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..backgroundColor = 'black'
      ..objectFit = 'contain';
    ui_web.platformViewRegistry
        .registerViewFactory(_viewType, (int _) => _video);
    _listen();
  }

  static int _nextView = 0;

  final String _viewType;
  late final web.HTMLVideoElement _video;
  final _subscriptions = <StreamSubscription<web.Event>>[];

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _tracks = StreamController<void>.broadcast();
  final _videoParams = StreamController<PlaybackVideoParams>.broadcast();
  final _failures = StreamController<PlaybackFailure>.broadcast();

  /// La source ouverte, null après [stop]. Sert à taire l'erreur que
  /// l'élément lève quand on lui retire sa source : ce n'est pas une panne.
  String? _source;
  bool _hls = false;
  bool _isBuffering = false;
  double _volume = 100;
  Duration? _pendingStart;
  List<String> _preferredLanguages = const [];

  // --- Surface -----------------------------------------------------------

  @override
  Widget buildSurface({
    Key? key,
    required BoxFit fit,
    double? aspectRatio,
    Rect? activeArea,
  }) {
    // Le cadrage appartient à l'élément : l'image est dans le plan vidéo, et
    // Flutter ne fait que réserver la place où elle apparaît.
    _video.style.objectFit = switch (fit) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
    return SizedBox.expand(
      key: key,
      child: HtmlElementView(viewType: _viewType),
    );
  }

  /// Les sous-titres sont des `<track>` dessinés par le navigateur, qui les
  /// place lui-même au bas de l'image.
  @override
  void setSubtitlePadding(EdgeInsets padding,
      {Duration duration = Duration.zero}) {}

  // --- Commandes ---------------------------------------------------------

  @override
  Future<void> prepare() async {}

  @override
  Future<void> dispose() async {
    await stop();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _video.remove();
    for (final controller in <StreamController<dynamic>>[
      _positions,
      _durations,
      _playing,
      _buffering,
      _completions,
      _tracks,
      _videoParams,
      _failures,
    ]) {
      await controller.close();
    }
  }

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) async {
    // Un hls.js resté attaché garderait la main sur l'élément : son
    // MediaSource remplacerait le fichier qu'on vient de lui donner.
    WebPlayback.releaseAllHlsSessions();
    _source = url;
    _hls = url.contains('.m3u8');
    _pendingStart = (start != null && start > Duration.zero) ? start : null;
    _setBuffering(true);

    if (_hls) {
      // L'élément reste tel quel : `adoptHlsSession`, appelé par le
      // contrôleur juste après, y attache hls.js — qui n'a besoin que d'être
      // chargé. Le point de départ fait partie de la session serveur.
      _pendingStart = null;
      _HlsScript.ensureLoaded();
    } else {
      _video.src = url;
      _video.load();
    }
    if (play) await this.play();
  }

  @override
  Future<void> play() async {
    try {
      await _video.play().toDart;
    } catch (e) {
      // Une lecture interrompue par l'ouverture suivante rejette sa promesse :
      // c'est la suivante qui compte. Une vraie panne arrive par `error`.
      debugPrint('WebOSPlayback: play() refusé ($e)');
    }
  }

  @override
  Future<void> pause() async => _video.pause();

  @override
  Future<void> seek(Duration position) async {
    _setBuffering(true);
    _video.currentTime = position.inMilliseconds / 1000;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    _video.volume = (volume / 100).clamp(0.0, 1.0);
  }

  @override
  Future<void> setRate(double rate) async => _video.playbackRate = rate;

  @override
  Future<void> setAudioTrack(PlaybackTrack track) async {
    final index = int.tryParse(track.id);
    final list = _audioTrackList();
    if (index == null || list == null || index >= list.length) return;
    // `enabled` sur une seule piste : en activer une ne désactive pas les
    // autres, et deux pistes actives se mélangent.
    for (var i = 0; i < list.length; i++) {
      list[i].enabled = i == index;
    }
    _tracks.add(null);
  }

  @override
  Future<void> setSubtitles(SubtitleSelection selection) async {
    switch (selection) {
      case SubtitleNone():
        WebPlayback.clearSubtitles();
      case SubtitleFromVtt(:final content, :final title, :final language):
        WebPlayback.showSubtitleVtt(content, language: language, label: title);
      case SubtitleFromTrack():
        // Les sous-titres d'un fichier ne sont pas exposés à la page : le
        // contrôleur passe par les WebVTT du serveur (voir [subtitleTracks]).
        break;
    }
  }

  @override
  Future<void> stop() async {
    WebPlayback.releaseAllHlsSessions();
    _source = null;
    _pendingStart = null;
    _video.pause();
    _video.removeAttribute('src');
    // Sans `load()`, l'élément garde sa connexion ouverte et continue de lire
    // le fichier qu'on vient de lui retirer.
    _video.load();
    _setBuffering(false);
  }

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => !_video.paused && !_video.ended;

  @override
  bool get isBuffering => _isBuffering;

  @override
  Duration get position => _seconds(_video.currentTime);

  @override
  Duration get duration => _seconds(_video.duration);

  @override
  Duration get bufferedAhead {
    final ranges = _video.buffered;
    final now = _video.currentTime;
    for (var i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= now && now <= ranges.end(i)) {
        return _seconds(ranges.end(i) - now);
      }
    }
    return Duration.zero;
  }

  /// Le pipeline ne dit pas ce qu'il reçoit. L'Auto se rabat alors sur la
  /// pente du tampon (ADR-0056).
  @override
  Future<int?> receivingBps() async => null;

  @override
  double get volume => _volume;

  @override
  PlaybackVideoParams get videoParams {
    final width = _video.videoWidth;
    final height = _video.videoHeight;
    if (width <= 0 || height <= 0) return PlaybackVideoParams.unknown;
    return PlaybackVideoParams(
        width: width, height: height, aspect: width / height);
  }

  /// Les pistes du fichier, dans leur ordre : le contrôleur fait correspondre
  /// la n-ième piste du serveur à la n-ième d'ici. Vide en HLS, où le serveur
  /// ne livre que la piste demandée — le contrôleur rouvre alors la session.
  @override
  List<PlaybackTrack> get audioTracks {
    final list = _hls ? null : _audioTrackList();
    if (list == null) return const [];
    return [
      for (var i = 0; i < list.length; i++)
        PlaybackTrack(
          id: '$i',
          title: list[i].label.isEmpty ? null : list[i].label,
          language: list[i].language.isEmpty ? null : list[i].language,
        ),
    ];
  }

  /// Toujours vide : une page ne voit que les `<track>` qu'on lui ajoute, et
  /// les sous-titres arrivent en WebVTT du serveur, Direct Play compris.
  @override
  List<PlaybackTrack> get subtitleTracks => const [];

  @override
  PlaybackTrack? get currentAudioTrack {
    final tracks = audioTracks;
    final list = _audioTrackList();
    if (list == null) return null;
    for (var i = 0; i < tracks.length; i++) {
      if (list[i].enabled) return tracks[i];
    }
    return null;
  }

  @override
  PlaybackTrack? get currentSubtitleTrack => null;

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

  // --- Réglages propres au moteur ----------------------------------------

  /// Les tampons sont ceux du pipeline du téléviseur, qu'une page ne règle pas.
  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) async {}

  /// En HLS, c'est la configuration de hls.js de la passerelle qui compte.
  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile,
      {bool sourceReady = false}) async {}

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    final quality = _video.getVideoPlaybackQuality();
    final elapsed = _video.currentTime;
    return PlaybackDiagnostics(
      hardwareDecoder: _hls ? 'webos (hls.js)' : 'webos (fichier)',
      droppedByDecoder: quality.droppedVideoFrames,
      renderedFrames: quality.totalVideoFrames - quality.droppedVideoFrames,
      estimatedFps: elapsed > 0 ? quality.totalVideoFrames / elapsed : null,
    );
  }

  /// Retenue pour l'arrivée des pistes : l'élément ne les liste qu'une fois
  /// l'en-tête lu, et c'est là qu'on active la bonne.
  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) async {
    _preferredLanguages = [for (final p in priorities) p.toLowerCase()];
  }

  /// L'élément cherche toujours à l'image près.
  @override
  Future<void> setExactSeek(bool exact) async {}

  /// Comme le reste du web : la barre lit la durée connue du contrôleur.
  @override
  Future<void> overrideDuration(Duration total) async {}

  @override
  Future<void> onPictureLive() async {}

  /// Une seule façon de dessiner ici ; un profil 5 est envoyé en HLS par le
  /// contrôleur (`dolbyVisionInDirectPlay` faux, voir les capacités webOS).
  @override
  Future<void> useDolbyVisionOutput() async {}

  // --- Événements de l'élément -------------------------------------------

  void _listen() {
    void on(web.EventStreamProvider<web.Event> provider,
        void Function(web.Event) handler) {
      _subscriptions.add(provider.forTarget(_video).listen(handler));
    }

    on(web.EventStreamProviders.timeUpdateEvent,
        (_) => _emit(_positions, position));
    on(web.EventStreamProviders.durationChangeEvent,
        (_) => _emit(_durations, duration));
    on(web.EventStreamProviders.playingEvent, (_) {
      _setBuffering(false);
      _emit(_playing, true);
    });
    on(web.EventStreamProviders.pauseEvent, (_) => _emit(_playing, false));
    on(web.EventStreamProviders.waitingEvent, (_) => _setBuffering(true));
    on(web.EventStreamProviders.seekingEvent, (_) => _setBuffering(true));
    on(web.EventStreamProviders.seekedEvent, (_) {
      if (_video.readyState >= 3) _setBuffering(false);
    });
    on(web.EventStreamProviders.canPlayEvent, (_) => _setBuffering(false));
    on(web.EventStreamProviders.endedEvent, (_) {
      _emit(_playing, false);
      _emit(_completions, null);
    });
    on(web.EventStreamProviders.loadedMetadataEvent, (_) => _onMetadata());
    on(web.EventStreamProviders.errorElementEvent, (_) => _onError());
  }

  void _onMetadata() {
    final start = _pendingStart;
    _pendingStart = null;
    // Après l'en-tête et non par `#t=` dans l'URL : le pipeline du téléviseur
    // reçoit l'adresse telle quelle, et rien ne garantit qu'il lise un
    // fragment de média.
    if (start != null) _video.currentTime = start.inMilliseconds / 1000;
    _selectPreferredAudio();
    _emit(_durations, duration);
    _emit(_videoParams, videoParams);
    _emit(_tracks, null);
  }

  void _selectPreferredAudio() {
    final list = _audioTrackList();
    if (list == null || _preferredLanguages.isEmpty) return;
    for (final wanted in _preferredLanguages) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].language.toLowerCase() == wanted) {
          for (var j = 0; j < list.length; j++) {
            list[j].enabled = j == i;
          }
          return;
        }
      }
    }
  }

  void _onError() {
    final error = _video.error;
    // Retirer la source lève une erreur « src vide » : ce n'est pas une panne.
    if (_source == null || error == null) return;
    // Un hls.js en charge a sa propre reprise, dans la passerelle : l'erreur
    // que l'élément remonte en route est déjà traitée là-bas.
    if (_hls) return;
    final kind = switch (error.code) {
      // Le pipeline du téléviseur répond 4 à un conteneur ou un codec qu'il
      // refuse — et, comme tout Chromium, à une réponse HTTP en erreur. Le
      // repli HLS qui suit le dira : une source vraiment perdue y échoue
      // aussi, et cette fois comme une panne.
      web.MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED ||
      web.MediaError.MEDIA_ERR_DECODE =>
        PlaybackFailureKind.unsupported,
      web.MediaError.MEDIA_ERR_NETWORK => PlaybackFailureKind.source,
      _ => PlaybackFailureKind.unknown,
    };
    _emit(
      _failures,
      PlaybackFailure(kind, 'webOS MediaError ${error.code}: ${error.message}'),
    );
  }

  void _setBuffering(bool buffering) {
    if (_isBuffering == buffering) return;
    _isBuffering = buffering;
    _emit(_buffering, buffering);
  }

  void _emit<T>(StreamController<T> controller, T value) {
    if (!controller.isClosed) controller.add(value);
  }

  /// `audioTracks`, s'il existe. Le moteur de webOS l'expose ; un Chromium de
  /// bureau le garde derrière un drapeau, et y toucher sans vérifier lèverait.
  web.AudioTrackList? _audioTrackList() {
    if (!(_video as JSObject).has('audioTracks')) return null;
    return _video.audioTracks;
  }

  static Duration _seconds(double value) => value.isFinite && value > 0
      ? Duration(milliseconds: (value * 1000).round())
      : Duration.zero;
}

/// hls.js, chargé une fois par page.
///
/// Ailleurs sur le web c'est media_kit qui l'injecte ; il n'est pas construit
/// ici. Même fichier et même version que lui, pour que la passerelle de
/// `WebPlayback` (qui intercepte `window.Hls`) parle au hls.js qu'elle connaît.
abstract final class _HlsScript {
  static const _url =
      'https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.4.10/hls.js';

  static bool _injected = false;

  static void ensureLoaded() {
    if (_injected) return;
    _injected = true;
    final script = web.HTMLScriptElement()
      ..src = _url
      ..async = true;
    (web.document.head ?? web.document.documentElement!).append(script);
  }
}
