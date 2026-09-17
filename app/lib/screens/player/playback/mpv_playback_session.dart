import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../../utils/app_platform.dart';
import '../../../utils/mpv_native_view.dart';
import '../hardware_decoding.dart';
import '../player_engine.dart';
import '../playback_profile.dart';
import 'cache_pause_policy.dart';
import 'mpv_native_surface.dart';
import 'mpv_subtitle_overlay.dart';
import 'playback_session.dart';
import 'seek_timeline.dart';
import 'texture_video_surface.dart';

/// Les niveaux de repli stéréo, dialogue en avant — voir l'ADR-0005.
///
/// Le centre passe au niveau des frontales (+3 dB sur les dialogues), les
/// surrounds gardent leur coefficient standard, et le LFE revient assez bas
/// pour donner du corps sans devenir le mixage. Posés sur le rééchantillonneur
/// que mpv utilise de toute façon, ils sont inertes quand aucune conversion de
/// disposition n'a lieu.
const String dialogueForwardMixLevels =
    'center_mix_level=1.0,surround_mix_level=0.7,lfe_mix_level=0.3';

/// [PlaybackSession] adossée à libmpv, via media_kit.
///
/// Passe-plat volontaire : tout ce qui pouvait rester au-dessus y est resté.
/// Ce fichier ne contient que ce qui n'a de sens que pour mpv — le vocabulaire
/// de ses options, et la façon dont il énumère ses pistes.
class MpvPlaybackSession implements PlaybackSession {
  /// Prend un moteur au vestiaire. Le rendre est le travail de [dispose].
  MpvPlaybackSession() : _engine = PlayerEnginePool.acquire();

  final PlayerEngine _engine;

  /// Clé de la vue vidéo, pour lui demander de décaler ses sous-titres.
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  /// Les sous-titres de la vue native, qui n'a pas ceux de media_kit.
  final GlobalKey<MpvSubtitleOverlayState> _subtitleKey =
      GlobalKey<MpvSubtitleOverlayState>();

  mk.Player get _player => _engine.player;

  /// Le moteur mpv sous-jacent.
  ///
  /// Exposé pour ce qui ne peut pas encore passer par le port : la mise en
  /// commun des instances entre deux lectures, et le lecteur web qui pilote
  /// hls.js à côté. À ne pas utiliser pour contourner l'interface.
  PlayerEngine get engine => _engine;

  @override
  Future<void> prepare() => _engine.settle();

  @override
  Future<void> dispose() async {
    _endSeekWatch(log: false);
    await _stopObserving();
    // Rendu plutôt que détruit : la lecture suivante réutilise cette instance
    // libmpv et sa texture au lieu de payer leur construction.
    PlayerEnginePool.release(_engine);
  }

  @override
  Widget buildSurface({Key? key, required BoxFit fit, double? aspectRatio}) {
    if (MpvNativeView.enabled) {
      return MpvNativeSurface(
        key: key,
        engine: _engine,
        fit: fit,
        aspectRatio: aspectRatio,
        subtitleKey: _subtitleKey,
      );
    }
    return TextureVideoSurface(
      key: key,
      controller: _engine.videoController!,
      videoKey: _videoKey,
      fit: fit,
      aspectRatio: aspectRatio,
    );
  }

  @override
  void setSubtitlePadding(EdgeInsets padding, {Duration duration = Duration.zero}) {
    _videoKey.currentState?.setSubtitleViewPadding(padding, duration: duration);
    _subtitleKey.currentState?.setPadding(padding, duration: duration);
  }

  // --- Commandes ---------------------------------------------------------

  @override
  Future<void> open(String url, {Duration? start, bool play = false}) {
    return _player.open(mk.Media(url, start: start), play: play);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) {
    _watchSeek(position);
    return _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setAudioTrack(PlaybackTrack track) {
    return _player.setAudioTrack(
      mk.AudioTrack(track.id, track.title, track.language),
    );
  }

  @override
  Future<void> setSubtitles(SubtitleSelection selection) {
    return switch (selection) {
      SubtitleNone() => _player.setSubtitleTrack(mk.SubtitleTrack.no()),
      SubtitleFromTrack(:final track) => _player.setSubtitleTrack(
          mk.SubtitleTrack(track.id, track.title, track.language),
        ),
      SubtitleFromVtt(:final content, :final title, :final language) =>
        _player.setSubtitleTrack(
          mk.SubtitleTrack.data(content, title: title, language: language),
        ),
    };
  }

  @override
  Future<void> stop() => _player.stop();

  // --- État --------------------------------------------------------------

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isBuffering => _player.state.buffering;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  Duration get bufferedAhead => _player.state.buffer;

  @override
  double get volume => _player.state.volume;

  @override
  PlaybackVideoParams get videoParams {
    final params = _player.state.videoParams;
    return PlaybackVideoParams(
      width: params.w ?? _player.state.width,
      height: params.h ?? _player.state.height,
      aspect: params.aspect,
    );
  }

  @override
  List<PlaybackTrack> get audioTracks =>
      _player.state.tracks.audio.map(_toTrack).toList();

  @override
  List<PlaybackTrack> get subtitleTracks =>
      _player.state.tracks.subtitle.map(_toTrack).toList();

  @override
  PlaybackTrack? get currentAudioTrack => _toTrack(_player.state.track.audio);

  @override
  PlaybackTrack? get currentSubtitleTrack =>
      _toTrack(_player.state.track.subtitle);

  static PlaybackTrack _toTrack(dynamic track) => PlaybackTrack(
        id: track.id as String,
        title: track.title as String?,
        language: track.language as String?,
      );

  // --- Flux --------------------------------------------------------------

  @override
  Stream<Duration> get positions => _player.stream.position;

  @override
  Stream<Duration> get durations => _player.stream.duration;

  @override
  Stream<bool> get playingChanges => _player.stream.playing;

  @override
  Stream<bool> get bufferingChanges => _player.stream.buffering;

  @override
  Stream<void> get completions =>
      _player.stream.completed.where((completed) => completed);

  @override
  Stream<void> get trackChanges => _player.stream.tracks;

  /// Les dimensions de l'image, quelle que soit la façon dont le moteur les
  /// annonce.
  ///
  /// mpv publie `videoParams`. Le backend web de media_kit publie pour cette
  /// propriété exactement une valeur — un `VideoParams` dont tous les champs
  /// sont nuls — et il l'émet depuis `stop()`. L'équivalent utilisable y est la
  /// taille intrinsèque de l'élément `<video>`, que media_kit publie bien.
  /// C'était une branche de plateforme dans le contrôleur ; elle appartient
  /// ici, où elle décrit une différence entre moteurs et non entre écrans.
  @override
  Stream<PlaybackVideoParams> get videoParamChanges {
    if (AppPlatform.isWeb) {
      return _player.stream.width.map(
        (width) => PlaybackVideoParams(
          width: width,
          height: _player.state.height,
          aspect: (width != null &&
                  width > 0 &&
                  (_player.state.height ?? 0) > 0)
              ? width / _player.state.height!
              : null,
        ),
      );
    }
    return _player.stream.videoParams.map(
      (params) => PlaybackVideoParams(
        width: params.w,
        height: params.h,
        aspect: params.aspect,
      ),
    );
  }

  // --- Réglages propres à mpv --------------------------------------------

  /// Pose une option mpv, sans laisser un refus emporter les suivantes.
  ///
  /// Ce bloc était une seule chaîne d'`await` : une option que mpv ne
  /// reconnaissait pas levait, et toutes celles d'après étaient silencieusement
  /// sautées — le décodeur matériel ou la reconnexion pouvaient manquer sans
  /// que rien ne le dise.
  Future<void> _set(dynamic platform, String name, String value) async {
    try {
      await platform.setProperty(name, value);
    } catch (e) {
      debugPrint('mpv: option $name=$value refusée: $e');
    }
  }

  Future<String?> _read(dynamic platform, String name) async {
    try {
      return await platform.getProperty(name) as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> applyDirectPlayTuning(PlaybackProfile profile) async {
    // Sur le web le backend est un HTMLVideoElement, sans `setProperty` : la
    // toute première ligne lèverait.
    if (AppPlatform.isWeb) return;
    final platform = _player.platform as dynamic;

    await _set(platform, 'audio-swresample-o', dialogueForwardMixLevels);
    await _set(platform, 'cache', 'yes');
    await _set(platform, 'demuxer-max-bytes', '${profile.demuxerMaxBytes}');
    await _set(platform, 'demuxer-readahead-secs', '${profile.readaheadSecs}');
    await _set(platform, 'demuxer-seekable-cache', 'yes');
    await _set(platform, 'demuxer-max-back-bytes', '${profile.demuxerBackBytes}');
    await _set(platform, 'hr-seek', 'yes');
    await _set(platform, 'hwdec', HardwareDecoding.mpvValue);
    await _resetZeroCopyCrop(platform);
    // Le rendu direct est une source connue de gels périodiques avec l'API de
    // rendu de libmpv qu'utilise media_kit. Android n'utilise pas cette API —
    // il reçoit une vraie Surface — et la copie supplémentaire y est tout sauf
    // négligeable sur une image 4K.
    if (!AppPlatform.isAndroid && !MpvNativeView.enabled) {
      await _set(platform, 'vd-lavc-dr', 'no');
    }
    await _set(platform, 'sub-auto', 'no');
    await _set(platform, 'network-timeout', '60');
    await _set(platform, 'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    _adaptCachePause = true;
    await _startObserving();
    await _set(platform, 'cache-pause', 'yes');
    await _set(platform, 'cache-pause-wait', '${_cachePause.waitSeconds}');
    // Pas au démarrage : l'écran couvre la vidéo jusqu'à ce que l'horloge
    // tourne, donc la première image que mpv montre pendant qu'il remplit son
    // cache restait cachée, et l'attente se voyait comme un démarrage lent.
    // Après la première image, en revanche, c'est ce qu'on veut — voir
    // [onPictureLive]. Posé ici aussi pour un retour du transcodage.
    await _set(platform, 'cache-pause-initial', _pictureLive ? 'yes' : 'no');
    await _set(platform, 'demuxer-cache-wait', 'no');
    // Plafonne le sondage du conteneur. FFmpeg analyse jusqu'à 5 s de média
    // avant de déclarer ses flux, et sur le réseau chacun de ces octets est de
    // l'attente devant la première image.
    await _set(platform, 'demuxer-lavf-analyzeduration', '2');
    if (!profile.allowHdrComputePeak) {
      await _set(platform, 'hdr-compute-peak', 'no');
    }
    // Contournement du pont de texture de media_kit, qui peut bloquer la sortie
    // vidéo : mpv saute des images au lieu de geler. La vue native n'a pas ce
    // pont, et display-desync y laisserait le son dériver de l'image — elle
    // garde le mode par défaut (voir _applyNativeOutputTuning).
    if (AppPlatform.isMacOS && !MpvNativeView.enabled) {
      await _set(platform, 'framedrop', 'vo');
      await _set(platform, 'video-sync', 'display-desync');
    }
    await _applyNativeOutputTuning();
  }

  /// Ce que la sortie native (gpu-next dans une vue AppKit) demande en plus.
  ///
  /// Passe par [MpvNativeOutput] et non par `_set` : ce sont des options de
  /// la sortie vidéo, appliquées hors du thread de l'interface.
  Future<void> _applyNativeOutputTuning() async {
    if (!MpvNativeView.enabled) return;
    final output = await _engine.nativeOutput;
    final properties = {
      // Laisse gpu-next passer l'écran en HDR (EDR) quand la source l'est.
      'target-colorspace-hint': 'yes',
      // Les touches média appartiennent au NowPlayingController de l'app.
      'input-media-keys': 'no',
      // Chaque image calée sur le son : le mode par défaut de mpv, dit
      // explicitement pour qu'aucun réglage de la texture ne s'y substitue.
      'video-sync': 'audio',
    };
    for (final entry in properties.entries) {
      try {
        await output.setProperty(entry.key, entry.value);
      } catch (e) {
        debugPrint('mpv: option ${entry.key}=${entry.value} refusée: $e');
      }
    }
  }

  @override
  Future<void> applyStreamingTuning(PlaybackProfile profile) async {
    if (AppPlatform.isWeb) return;
    final platform = _player.platform as dynamic;

    // Les mêmes niveaux de repli qu'en lecture directe. Le serveur livre déjà
    // des renditions stéréo, donc il n'y a normalement rien à convertir — mais
    // le moteur est mis en commun et ses options survivent à une lecture, donc
    // les deux chemins disent la même chose plutôt qu'un des deux ne dise rien.
    await _set(platform, 'audio-swresample-o', dialogueForwardMixLevels);
    await _set(platform, 'force-seekable', 'yes');
    await _set(platform, 'cache', 'yes');
    await _set(platform, 'demuxer-seekable-cache', 'yes');
    await _set(platform, 'demuxer-max-bytes', '${profile.hlsDemuxerMaxBytes}');
    await _set(platform, 'demuxer-readahead-secs', '${profile.hlsReadaheadSecs}');
    await _set(platform, 'hwdec', HardwareDecoding.mpvValue);
    await _resetZeroCopyCrop(platform);
    if (!AppPlatform.isAndroid && !MpvNativeView.enabled) {
      await _set(platform, 'vd-lavc-dr', 'no');
    }
    if (!profile.allowHdrComputePeak) {
      await _set(platform, 'hdr-compute-peak', 'no');
    }
    await _set(platform, 'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    // En transcodage, une coupure vient le plus souvent de l'encodeur et non
    // du réseau : l'attente reste fixe.
    _adaptCachePause = false;
    await _startObserving();
    await _set(platform, 'cache-pause', 'yes');
    await _set(platform, 'cache-pause-wait', '3');
    await _set(platform, 'cache-pause-initial', 'yes');
    // Contournement du pont de texture de media_kit, qui peut bloquer la sortie
    // vidéo : mpv saute des images au lieu de geler. La vue native n'a pas ce
    // pont, et display-desync y laisserait le son dériver de l'image — elle
    // garde le mode par défaut (voir _applyNativeOutputTuning).
    if (AppPlatform.isMacOS && !MpvNativeView.enabled) {
      await _set(platform, 'framedrop', 'vo');
      await _set(platform, 'video-sync', 'display-desync');
    }
    await _applyNativeOutputTuning();
  }

  // --- Reprise après un seek ou une coupure --------------------------------

  /// L'attente du cache suit ce que la connexion a montré — voir
  /// [CachePausePolicy]. Seulement en lecture directe.
  final CachePausePolicy _cachePause = CachePausePolicy();
  bool _adaptCachePause = false;

  /// La première image de cette lecture a été vue ([onPictureLive]).
  bool _pictureLive = false;

  bool _observing = false;
  SeekTimeline? _seekTimeline;
  StreamSubscription<Duration>? _seekPositions;
  Timer? _seekTimeout;

  static const _observed = ['seeking', 'paused-for-cache'];

  Future<void> _startObserving() async {
    if (_observing) return;
    _observing = true;
    final platform = _player.platform as dynamic;
    for (final name in _observed) {
      Future<void> listener(String value) async => _onObserved(name, value);
      try {
        await platform.observeProperty(name, listener);
      } on ArgumentError {
        // Le moteur est mis en commun : une session qui n'a pas été rendue
        // proprement a laissé son observateur. On prend sa place.
        try {
          await platform.unobserveProperty(name);
          await platform.observeProperty(name, listener);
        } catch (e) {
          debugPrint('mpv: observation de $name impossible: $e');
        }
      } catch (e) {
        debugPrint('mpv: observation de $name impossible: $e');
      }
    }
  }

  Future<void> _stopObserving() async {
    if (!_observing) return;
    _observing = false;
    final platform = _player.platform as dynamic;
    for (final name in _observed) {
      try {
        await platform.unobserveProperty(name);
      } catch (_) {}
    }
  }

  void _onObserved(String name, String value) {
    final on = value == 'yes';
    final timeline = _seekTimeline;
    if (name == 'seeking') {
      timeline?.noteSeeking(on);
      return;
    }
    timeline?.notePausedForCache(on);
    // Une mise en pause pendant qu'un seek repart est l'attente voulue, pas une
    // coupure : seule celle qui interrompt une lecture en cours compte.
    if (!on || timeline != null || !_adaptCachePause || !_pictureLive) return;
    if (!_cachePause.noteUnderrun(DateTime.now())) return;
    final wait = _cachePause.waitSeconds;
    debugPrint('mpv: la connexion ne suit pas le débit — reprise après '
        '${wait}s en mémoire');
    unawaited(
        _set(_player.platform as dynamic, 'cache-pause-wait', '$wait'));
  }

  /// Suit le seek vers [target] jusqu'à ce que la lecture reparte, et le dit
  /// dans le log.
  void _watchSeek(Duration target) {
    if (AppPlatform.isWeb) return;
    if (_adaptCachePause && _cachePause.relaxIfCalm(DateTime.now())) {
      unawaited(_set(_player.platform as dynamic, 'cache-pause-wait',
          '${_cachePause.waitSeconds}'));
    }
    // Un glissement de la tête de lecture enchaîne les seeks : seul le
    // dernier a une reprise à mesurer.
    _endSeekWatch(log: false);
    final clock = Stopwatch()..start();
    final timeline = SeekTimeline(
      target: target,
      startPosition: _player.state.position,
      elapsed: () => clock.elapsed,
    );
    _seekTimeline = timeline;
    _seekPositions = _player.stream.position.listen((position) {
      if (timeline.notePosition(position)) _endSeekWatch(log: true);
    });
    _seekTimeout = Timer(const Duration(seconds: 30), () {
      // Mis en pause par l'utilisateur : rien à mesurer.
      _endSeekWatch(log: _player.state.playing);
    });
  }

  void _endSeekWatch({required bool log}) {
    final timeline = _seekTimeline;
    _seekTimeline = null;
    _seekPositions?.cancel();
    _seekPositions = null;
    _seekTimeout?.cancel();
    _seekTimeout = null;
    if (!log || timeline == null) return;
    final ahead = _player.state.buffer - _player.state.position;
    unawaited(_read(_player.platform as dynamic, 'cache-speed').then((speed) {
      final bytes = int.tryParse(speed ?? '');
      debugPrint(timeline.describe(
        cacheAhead: ahead.isNegative ? Duration.zero : ahead,
        bitsPerSecond: bytes == null ? null : bytes * 8,
      ));
    }));
  }

  @override
  Future<void> setPreferredAudioLanguages(List<String> priorities) async {
    if (AppPlatform.isWeb) return;
    // mpv prend une liste de priorité en une seule propriété.
    await _set(_player.platform as dynamic, 'alang', priorities.join(','));
  }

  @override
  Future<void> setExactSeek(bool exact) async {
    if (AppPlatform.isWeb) return;
    await _set(_player.platform as dynamic, 'hr-seek', exact ? 'yes' : 'no');
  }

  @override
  Future<void> overrideDuration(Duration total) async {
    if (AppPlatform.isWeb) return;
    await _set(_player.platform as dynamic, 'length',
        (total.inMilliseconds / 1000).toStringAsFixed(3));
  }

  /// Un seul échange de décodeur par lecture.
  bool _softwareDecodeHandled = false;

  /// Dit dans le log si le Dolby Vision est réellement appliqué.
  ///
  /// Trois questions, trois réponses de mpv : le fichier en porte-t-il (profil
  /// et niveau de la piste), la couche RPU est-elle appliquée à l'image (mpv
  /// passe alors sa matrice en `dolbyvision`), et l'écran est-il piloté en HDR
  /// (la courbe de sortie de gpu-next).
  Future<void> _logDolbyVision() async {
    final platform = _player.platform as dynamic;
    Future<String?> read(String name) async {
      final value = await _read(platform, name);
      return (value == null || value.isEmpty) ? null : value;
    }

    final profile = await read('current-tracks/video/dolby-vision-profile');
    final level = await read('current-tracks/video/dolby-vision-level');
    final matrix = await read('video-params/colormatrix');
    final source = '${await read('video-params/gamma')}/'
        '${await read('video-params/primaries')}';
    final target = '${await read('video-target-params/gamma')}/'
        '${await read('video-target-params/primaries')}';
    final peak = await read('video-target-params/max-luma');

    final dolbyVision = profile == null
        ? 'aucun (le fichier n\'en porte pas)'
        : 'profil $profile niveau ${level ?? '?'} · RPU '
            '${matrix == 'dolbyvision' ? 'appliqué' : 'NON appliqué (matrice $matrix)'}';
    debugPrint('Dolby Vision: $dolbyVision · source $source → écran $target'
        '${peak != null ? ' ($peak nits)' : ''}');
  }

  /// Le moteur est mis en commun : un rognage posé pour la lecture précédente
  /// ne doit pas survivre à la suivante. `""` rend le rognage du conteneur.
  Future<void> _resetZeroCopyCrop(dynamic platform) async {
    if (AppPlatform.isWindows) await _set(platform, 'video-crop', '');
  }

  /// Cache la bande verte que le décodage sans copie laisse au bord de l'image
  /// — voir [HardwareDecoding.zeroCopyEdgeCrop].
  Future<void> _cropZeroCopyPadding() async {
    if (!AppPlatform.isWindows) return;
    final platform = _player.platform as dynamic;
    // `d3d11va` seul : `d3d11va-copy` et le logiciel n'exposent que l'image.
    final decoded = (await _read(platform, 'hwdec-current') ?? '').trim();
    if (decoded != 'd3d11va') return;
    final params = _player.state.videoParams;
    final width = params.w;
    final height = params.h;
    if (width == null || height == null) return;
    final crop = HardwareDecoding.zeroCopyEdgeCrop(width, height);
    if (crop == null) return;
    await _set(platform, 'video-crop', crop);
  }

  @override
  Future<void> onPictureLive() async {
    if (!AppPlatform.isWeb) {
      _pictureLive = true;
      // Désormais, un seek hors du cache montre sa première image tout de suite
      // puis attend d'avoir de quoi lire avant de repartir. Sans ça, mpv
      // repartait sur la seule image décodée, tombait à sec une demi-seconde
      // plus loin et se mettait en pause : image, blocage, image.
      if (_adaptCachePause) {
        await _set(_player.platform as dynamic, 'cache-pause-initial', 'yes');
      }
    }
    if (MpvNativeView.enabled && !AppPlatform.isWeb) await _logDolbyVision();
    if (AppPlatform.isWeb) return;
    await _cropZeroCopyPadding();
    if (_softwareDecodeHandled) return;
    // Les deux plateformes où le chemin sans copie peut échouer vers le
    // logiciel : MediaCodec sur Android, l'interop d3d11-egl sur Windows.
    if (!AppPlatform.isAndroid && !AppPlatform.isWindows) return;
    if (HardwareDecoding.preference != HardwareDecodingPreference.auto) return;

    final platform = _player.platform as dynamic;
    final height = _player.state.videoParams.h;
    if (height == null || height < 1440) return;

    // « no » quand rien n'a pris ; certaines constructions répondent une chaîne
    // vide. mpv se rabat de `mediacodec` **directement** sur le logiciel — il
    // n'y a pas d'étape intermédiaire — donc le chemin compatible, qui est du
    // matériel lui aussi, n'est jamais essayé. C'est cette étape-là.
    final decoded = (await _read(platform, 'hwdec-current') ?? '').trim();
    if (decoded.isNotEmpty && decoded != 'no') return;

    _softwareDecodeHandled = true;
    HardwareDecoding.noteZeroCopyFailure();
    debugPrint('mpv: ${height}p décodé en logiciel — bascule sur '
        '${HardwareDecoding.mpvValue}');
    await _set(platform, 'hwdec', HardwareDecoding.mpvValue);
  }

  @override
  Future<PlaybackDiagnostics> readDiagnostics() async {
    if (AppPlatform.isWeb) return PlaybackDiagnostics.none;
    final platform = _player.platform as dynamic;
    return PlaybackDiagnostics(
      videoCodec: await _read(platform, 'video-codec'),
      // `hwdec-current` est la réponse de mpv, pas ce qu'on lui a demandé : un
      // décodeur qui n'a pas démarré se rabat en silence.
      hardwareDecoder: await _read(platform, 'hwdec-current'),
      containerFps:
          double.tryParse(await _read(platform, 'container-fps') ?? ''),
      droppedByDisplay:
          int.tryParse(await _read(platform, 'frame-drop-count') ?? ''),
      droppedByDecoder:
          int.tryParse(await _read(platform, 'decoder-frame-drop-count') ?? ''),
      sourceChannels: await _read(platform, 'audio-params/channel-count'),
      outputChannels: await _read(platform, 'audio-out-params/channel-count'),
      audioCodec: await _read(platform, 'audio-codec-name'),
    );
  }
}
