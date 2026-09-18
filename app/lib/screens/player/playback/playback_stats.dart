import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_session.dart';

/// Ce qu'une lecture a vraiment fait, mesuré pendant qu'elle avait lieu.
///
/// Le journal dit ce qui s'est passé, en phrases. Il ne dit pas si le film a
/// tourné à sa cadence, quel décodeur l'a réellement pris en charge, ni combien
/// de mégabits la séance a tirés par seconde — et ce sont les trois questions
/// qu'on se pose devant une lecture qui saccade sans jamais tomber en panne.
///
/// Les chiffres sont relevés par échantillons ([PlaybackStatsCollector]) et
/// résumés une fois, à la fin, pour partir avec le journal.
class PlaybackStatsSummary {
  const PlaybackStatsSummary({
    required this.sampledSeconds,
    required this.sampleCount,
    this.averageFps,
    this.containerFps,
    this.averageBitrateBps,
    this.videoBitrateBps,
    this.audioBitrateBps,
    this.droppedFrames,
    this.renderedFrames,
    this.videoCodec,
    this.audioCodec,
    this.decoder,
    this.bufferingEvents = 0,
    this.bufferingSeconds = 0,
    this.startupMillis,
  });

  /// Combien de temps la mesure a duré. Sans ça, une moyenne ne veut rien dire :
  /// quarante images par seconde sur deux échantillons décrit un démarrage, pas
  /// une séance.
  final double sampledSeconds;
  final int sampleCount;

  /// La cadence rendue, moyennée sur les échantillons.
  final double? averageFps;

  /// Celle que le fichier annonce. L'écart avec [averageFps] est le symptôme.
  final double? containerFps;

  /// Le débit moyen de la séance, déduit des octets réellement tirés.
  final double? averageBitrateBps;

  /// Les débits déclarés par les pistes, moyennés sur les échantillons.
  final double? videoBitrateBps;
  final double? audioBitrateBps;

  final int? droppedFrames;
  final int? renderedFrames;

  final String? videoCodec;
  final String? audioCodec;

  /// Le décodeur réellement instancié — `hwdec-current` côté mpv, le nom
  /// MediaCodec côté Android.
  final String? decoder;

  /// Les mises en mémoire tampon après le démarrage. Une lecture qui repart
  /// douze fois n'est pas la même chose qu'une lecture qui n'a jamais démarré,
  /// et l'historique ne distinguait ni l'une ni l'autre.
  final int bufferingEvents;
  final double bufferingSeconds;

  /// Le délai jusqu'à la première image, en millisecondes.
  final int? startupMillis;

  /// La proportion d'images perdues, entre 0 et 1. Null quand rien n'a été
  /// rendu — auquel cas il n'y a pas de proportion, seulement une panne.
  double? get dropRatio {
    final dropped = droppedFrames;
    final rendered = renderedFrames;
    if (dropped == null || rendered == null) return null;
    final total = dropped + rendered;
    if (total <= 0) return null;
    return dropped / total;
  }

  /// Vrai quand la mesure n'a rien à dire — une séance trop courte pour qu'un
  /// seul échantillon soit tombé. Envoyer un résumé vide encombrerait
  /// l'historique de blocs qui ne répondent à aucune question.
  bool get isEmpty => sampleCount == 0;

  Map<String, dynamic> toJson() => {
        'sampled_seconds': sampledSeconds,
        'sample_count': sampleCount,
        if (averageFps != null) 'average_fps': averageFps,
        if (containerFps != null) 'container_fps': containerFps,
        if (averageBitrateBps != null) 'average_bitrate_bps': averageBitrateBps,
        if (videoBitrateBps != null) 'video_bitrate_bps': videoBitrateBps,
        if (audioBitrateBps != null) 'audio_bitrate_bps': audioBitrateBps,
        if (droppedFrames != null) 'dropped_frames': droppedFrames,
        if (renderedFrames != null) 'rendered_frames': renderedFrames,
        if (videoCodec != null) 'video_codec': videoCodec,
        if (audioCodec != null) 'audio_codec': audioCodec,
        if (decoder != null) 'decoder': decoder,
        'buffering_events': bufferingEvents,
        'buffering_seconds': bufferingSeconds,
        if (startupMillis != null) 'startup_ms': startupMillis,
      };
}

/// Relève les compteurs du moteur à intervalle régulier et en tire un résumé.
///
/// Un seul relevé à la fin ne suffirait pas : la cadence et le débit sont des
/// grandeurs instantanées, et celle qu'on lirait juste avant la fermeture
/// décrirait la dernière seconde du générique. Les compteurs cumulés, eux,
/// posent le problème inverse — ils sont remis à zéro par le moteur à chaque
/// ouverture, et une séance en compte plusieurs dès qu'on change de qualité.
/// D'où les deux traitements côte à côte : moyenne pour ce qui est instantané,
/// cumul rattrapé pour ce qui compte.
class PlaybackStatsCollector {
  PlaybackStatsCollector({this.interval = const Duration(seconds: 5)});

  final Duration interval;

  Timer? _timer;
  PlaybackSession? _session;
  final Stopwatch _elapsed = Stopwatch();

  int _samples = 0;
  double _fpsSum = 0;
  int _fpsSamples = 0;
  double _videoBitrateSum = 0;
  int _videoBitrateSamples = 0;
  double _audioBitrateSum = 0;
  int _audioBitrateSamples = 0;

  double? _containerFps;
  String? _videoCodec;
  String? _audioCodec;
  String? _decoder;

  // Les compteurs cumulés du moteur, rattrapés à travers ses remises à zéro.
  // `_base` est ce qu'ont laissé les ouvertures précédentes de la séance,
  // `_last` le dernier relevé de l'ouverture en cours.
  int _droppedBase = 0;
  int _droppedLast = 0;
  int _renderedBase = 0;
  int _renderedLast = 0;
  int _bytesBase = 0;
  int _bytesLast = 0;

  // Un compteur qu'aucun échantillon n'a renseigné n'est pas un compteur à
  // zéro. La distinction porte tout le sens de la case : « zéro image perdue »
  // est une bonne nouvelle, « pas mesuré » n'en est pas une, et un moteur qui
  // ne sait pas compter les images perdues rendrait sinon le plus flatteur des
  // deux résultats sans avoir rien mesuré.
  bool _sawDropped = false;
  bool _sawRendered = false;
  bool _sawBytes = false;

  int _bufferingEvents = 0;
  final Stopwatch _bufferingWatch = Stopwatch();
  int? _startupMillis;

  bool get isRunning => _timer != null;

  void start(PlaybackSession session) {
    stop();
    _session = session;
    _elapsed.start();
    // Un premier relevé tout de suite : le codec et le décodeur sont connus dès
    // l'ouverture, et une lecture abandonnée avant le premier intervalle doit
    // pouvoir dire au moins par quoi elle est passée.
    unawaited(_sample());
    _timer = Timer.periodic(interval, (_) => unawaited(_sample()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _elapsed.stop();
    _bufferingWatch.stop();
  }

  /// Le temps passé à remplir le tampon, compté séparément du reste.
  void noteBuffering(bool buffering) {
    if (buffering) {
      if (_bufferingWatch.isRunning) return;
      _bufferingEvents++;
      _bufferingWatch.start();
    } else {
      _bufferingWatch.stop();
    }
  }

  void noteStartup(int millis) => _startupMillis ??= millis;

  /// Un dernier relevé, puis le résumé. Appelé à l'arrêt : ce qui s'est passé
  /// depuis le dernier échantillon compte autant que le reste, et c'est souvent
  /// là que la lecture s'est dégradée.
  Future<PlaybackStatsSummary> finish() async {
    await _sample();
    stop();
    return summary;
  }

  PlaybackStatsSummary get summary => PlaybackStatsSummary(
        sampledSeconds: _elapsed.elapsedMilliseconds / 1000,
        sampleCount: _samples,
        averageFps: _fpsSamples == 0 ? null : _fpsSum / _fpsSamples,
        containerFps: _containerFps,
        averageBitrateBps: _averageBitrate,
        videoBitrateBps: _videoBitrateSamples == 0
            ? null
            : _videoBitrateSum / _videoBitrateSamples,
        audioBitrateBps: _audioBitrateSamples == 0
            ? null
            : _audioBitrateSum / _audioBitrateSamples,
        droppedFrames: _sawDropped ? _droppedBase + _droppedLast : null,
        renderedFrames: _sawRendered ? _renderedBase + _renderedLast : null,
        videoCodec: _videoCodec,
        audioCodec: _audioCodec,
        decoder: _decoder,
        bufferingEvents: _bufferingEvents,
        bufferingSeconds: _bufferingWatch.elapsedMilliseconds / 1000,
        startupMillis: _startupMillis,
      );

  /// Ce qui a transité, rapporté au temps écoulé.
  ///
  /// Null quand le moteur ne compte pas les octets : une moyenne inventée
  /// serait pire qu'une case vide, puisque rien ne la distinguerait d'une
  /// mesure.
  double? get _averageBitrate {
    if (!_sawBytes) return null;
    final bytes = _bytesBase + _bytesLast;
    final seconds = _elapsed.elapsedMilliseconds / 1000;
    if (bytes <= 0 || seconds <= 0) return null;
    return bytes * 8 / seconds;
  }

  Future<void> _sample() async {
    final session = _session;
    if (session == null) return;
    late final PlaybackDiagnostics info;
    try {
      info = await session.readDiagnostics();
    } catch (_) {
      // Un moteur fermé pendant le relevé, une plateforme qui ne répond pas :
      // une mesure manquée ne vaut pas la peine d'être signalée, et surtout pas
      // d'interrompre la lecture.
      return;
    }
    _samples++;

    final fps = info.estimatedFps;
    if (fps != null && fps > 0) {
      _fpsSum += fps;
      _fpsSamples++;
    }
    final videoBitrate = info.videoBitrate;
    if (videoBitrate != null && videoBitrate > 0) {
      _videoBitrateSum += videoBitrate;
      _videoBitrateSamples++;
    }
    final audioBitrate = info.audioBitrate;
    if (audioBitrate != null && audioBitrate > 0) {
      _audioBitrateSum += audioBitrate;
      _audioBitrateSamples++;
    }

    _containerFps = info.containerFps ?? _containerFps;
    _videoCodec = info.videoCodec ?? _videoCodec;
    _audioCodec = info.audioCodec ?? _audioCodec;
    _decoder = info.hardwareDecoder ?? _decoder;

    if (info.droppedByDisplay != null) _sawDropped = true;
    if (info.renderedFrames != null) _sawRendered = true;
    if (info.bytesLoaded != null) _sawBytes = true;

    _droppedLast = _accumulate(
        info.droppedByDisplay, _droppedLast, (base) => _droppedBase += base);
    _renderedLast = _accumulate(
        info.renderedFrames, _renderedLast, (base) => _renderedBase += base);
    _bytesLast =
        _accumulate(info.bytesLoaded, _bytesLast, (base) => _bytesBase += base);
  }

  /// Prend un échantillon maintenant.
  ///
  /// Le collecteur relève sur minuterie ; un test qui attendrait cinq secondes
  /// par échantillon mesurerait surtout la patience de celui qui le lance.
  @visibleForTesting
  Future<void> sampleNow() => _sample();

  /// Suit un compteur qui peut repartir de zéro.
  ///
  /// Le moteur remet ses compteurs à chaque ouverture, et une séance en compte
  /// plusieurs — le changement de qualité en est une. Une valeur plus basse que
  /// la précédente ne peut donc signifier qu'une chose : le compteur a
  /// recommencé, et ce qu'il portait avant doit passer au cumul avant d'être
  /// oublié.
  int _accumulate(int? value, int previous, void Function(int base) addBase) {
    if (value == null) return previous;
    if (value < previous) {
      addBase(previous);
      return value;
    }
    return value;
  }
}
