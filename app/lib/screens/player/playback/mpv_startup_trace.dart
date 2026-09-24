import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../../services/playback_access.dart';

/// La trace d'un démarrage mpv, de l'ouverture à la première image.
///
/// Trois choses dans le journal : les lignes de mpv lui-même (voir
/// [MpvStartupTrace]), les notes de la session (attente du cache, piste
/// changée en route), et un bilan à l'image — où la lecture s'est posée, ce
/// qu'elle avait d'avance, à quelle vitesse les octets arrivaient. Hors de
/// cette fenêtre, rien : c'est un outil de démarrage, pas un second journal.
class MpvStartupProbe {
  MpvStartupProbe(this._player);

  final mk.Player _player;
  final Stopwatch _clock = Stopwatch();
  MpvStartupTrace? _trace;
  StreamSubscription<mk.PlayerLog>? _logs;
  Timer? _timeout;
  Duration? _requestedStart;
  bool _keyframeStart = false;

  /// Au-delà, le démarrage est en panne et l'écran le dit ; la trace s'arrête
  /// pour ne pas remplir le journal d'une lecture qui ne viendra pas.
  static const _deadline = Duration(seconds: 30);

  bool get isActive => _trace != null;

  void begin({Duration? start, required bool keyframeStart}) {
    _stop();
    final trace = MpvStartupTrace();
    _trace = trace;
    _requestedStart = start;
    _keyframeStart = keyframeStart;
    _clock
      ..reset()
      ..start();
    _logs = _player.stream.log.listen((log) {
      final line = trace.line(log.prefix, log.level, log.text, _clock.elapsed);
      if (line != null) debugPrint(line);
    });
    _timeout = Timer(_deadline, () {
      note("toujours pas d'image — trace arrêtée");
      _stop();
    });
  }

  /// Une ligne datée depuis l'ouverture, pendant le démarrage seulement.
  void note(String what) {
    if (!isActive) return;
    debugPrint('mpv +${_clock.elapsed.inMilliseconds}ms $what');
  }

  /// Clôt la trace sur son bilan. [read] lit une propriété mpv.
  Future<void> finish(Future<String?> Function(String name) read) async {
    if (!isActive) return;
    final at = _clock.elapsed;
    final start = _requestedStart;
    final keyframe = _keyframeStart;
    _stop();
    double? number(String? raw) => double.tryParse(raw ?? '');
    debugPrint(describeLanding(
      at: at,
      requestedStart: start,
      keyframeStart: keyframe,
      landedAt: number(await read('time-pos')),
      aheadSeconds: number(await read('demuxer-cache-duration')),
      aheadBytes: number(await read('demuxer-cache-state/fw-bytes')),
      bytesPerSecond: number(await read('cache-speed')),
    ));
  }

  void cancel() => _stop();

  void _stop() {
    final summary = _trace?.summary();
    if (summary != null) debugPrint(summary);
    _trace = null;
    _logs?.cancel();
    _logs = null;
    _timeout?.cancel();
    _timeout = null;
    _clock.stop();
  }

  /// Le bilan à l'image, en une ligne.
  ///
  /// La réception est en mégabits, pour se lire contre le débit du film que
  /// donne la fiche de lecture ; l'écart au point demandé dit ce que le départ
  /// sur image clé a fait revoir.
  @visibleForTesting
  static String describeLanding({
    required Duration at,
    Duration? requestedStart,
    required bool keyframeStart,
    double? landedAt,
    double? aheadSeconds,
    double? aheadBytes,
    double? bytesPerSecond,
  }) {
    final parts = <String>[];
    if (landedAt != null) {
      final asked = requestedStart == null
          ? ''
          : ' pour ${requestedStart.inSeconds}s demandées'
              ' (${keyframeStart ? 'image clé' : 'précis'}, écart '
              '${(landedAt - requestedStart.inMilliseconds / 1000).toStringAsFixed(1)}s)';
      parts.add('posée à ${landedAt.toStringAsFixed(1)}s$asked');
    }
    if (aheadSeconds != null) {
      parts.add('${aheadSeconds.toStringAsFixed(1)}s en avance'
          '${aheadBytes == null ? '' : ' (${(aheadBytes / 1e6).toStringAsFixed(1)} Mo)'}');
    }
    if (bytesPerSecond != null) {
      parts.add(
          'réception ${(bytesPerSecond * 8 / 1e6).toStringAsFixed(1)} Mb/s');
    }
    return 'mpv: bilan du démarrage à +${at.inMilliseconds}ms'
        '${parts.isEmpty ? '' : ' — ${parts.join(' · ')}'}';
  }
}

/// Ce que mpv dit de lui-même entre l'ouverture et la première image, trié.
///
/// La ligne `PLAYER STARTUP` s'arrête aux portes du moteur : entre `play` et
/// la première image, elle ne voit qu'un bloc. mpv, en verbeux, raconte ce
/// bloc — ouverture du flux, format détecté, lecture de l'index, seek initial,
/// décodeur choisi, sorties audio et vidéo, « playback restart complete » — et
/// l'heure de chaque ligne dit où le temps passe.
///
/// Trié parce que le verbeux complet noierait le journal (six cents lignes en
/// tout, voir `ClientLog.capacity`) : seuls les modules qui décrivent le
/// chemin vers la première image passent, la sortie vidéo exceptée (elle
/// détaille chaque shader), et le total est plafonné. Masqué parce que l'URL du
/// flux porte le ticket de lecture, et que ce journal part au serveur.
class MpvStartupTrace {
  MpvStartupTrace({this.maxLines = 60});

  final int maxLines;
  int _written = 0;
  int _dropped = 0;

  static const _levels = {'fatal', 'error', 'warn', 'info', 'v'};

  /// Modules gardés, avec leurs sous-modules (`ffmpeg/demuxer`, `ao/wasapi`).
  static const _modules = {
    'cplayer',
    'demux',
    'mkv',
    'lavf',
    'stream',
    'file',
    'ffmpeg',
    'cache',
    'vd',
    'ad',
    'ao',
  };

  /// Lignes du lecteur qui décrivent les commandes de l'app, pas le chargement.
  static const _noise = [
    'Set property',
    'Run command',
    'Setting option',
    'Property ',
    'Command ',
  ];

  /// La ligne à écrire pour ce message, ou null s'il ne dit rien du démarrage
  /// ou que le plafond est atteint.
  String? line(String prefix, String level, String text, Duration sinceOpen) {
    final message = text.trim();
    if (message.isEmpty || !_levels.contains(level) || !_keeps(prefix)) {
      return null;
    }
    if (prefix == 'cplayer' && _noise.any(message.startsWith)) return null;
    if (_written >= maxLines) {
      _dropped++;
      return null;
    }
    _written++;
    return 'mpv +${sinceOpen.inMilliseconds}ms [$prefix] '
        '${redactPlaybackDiagnostic(message)}';
  }

  /// Ce que le plafond a coupé, à écrire en fin de trace ; null si rien.
  String? summary() => _dropped == 0
      ? null
      : 'mpv: $_dropped lignes de démarrage non écrites '
          '(plafond de $maxLines)';

  static bool _keeps(String prefix) {
    final module = prefix.split('/').first;
    return _modules.contains(module);
  }
}
