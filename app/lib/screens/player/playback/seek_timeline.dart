/// Ce qui s'est passé entre un seek et le moment où l'image repart.
///
/// Un seek lent a trois coupables possibles, et ils ne se soignent pas pareil :
/// le réseau (les octets à la cible arrivent tard), le décodage ou la sortie
/// vidéo (les octets sont là, l'image ne vient pas), ou l'attente volontaire du
/// cache. Vu de l'écran, c'est le même spinner. La ligne que produit
/// [describe] les sépare : un cache bien rempli à la reprise après une longue
/// attente, c'est que le réseau n'y est pour rien.
///
/// Pure — les horloges et les valeurs viennent de l'appelant — pour pouvoir
/// être vérifiée sans moteur.
class SeekTimeline {
  SeekTimeline({
    required this.target,
    required Duration startPosition,
    required Duration Function() elapsed,
  })  : _elapsed = elapsed,
        _last = startPosition,
        _start = startPosition;

  /// Où le seek a été demandé, sur la ligne de temps du moteur.
  final Duration target;

  final Duration Function() _elapsed;
  final Duration _start;
  Duration _last;

  /// La tête de lecture a quitté l'ancienne position.
  bool _jumped = false;

  /// La position d'où l'on mesure l'avancée : là où la tête a atterri. Un seek
  /// au point-clé atterrit avant la cible, d'où le recul qui la redéfinit.
  Duration _landing = Duration.zero;

  Duration? _pictureAt;
  Duration? _resumedAt;
  Duration? _cachePauseSince;
  Duration _cachePaused = Duration.zero;
  int _cachePauses = 0;

  bool get resumed => _resumedAt != null;

  /// mpv a fini de se replacer : la première image est à l'écran.
  void noteSeeking(bool seeking) {
    if (!seeking && _pictureAt == null && !resumed) _pictureAt = _elapsed();
  }

  void notePausedForCache(bool paused) {
    if (resumed) return;
    final now = _elapsed();
    if (paused && _cachePauseSince == null) {
      _cachePauseSince = now;
      _cachePauses++;
    } else if (!paused && _cachePauseSince != null) {
      _cachePaused += now - _cachePauseSince!;
      _cachePauseSince = null;
    }
  }

  /// Renvoie `true` à la position qui montre que la lecture est repartie.
  bool notePosition(Duration position) {
    if (resumed) return false;
    const step = Duration(seconds: 1);
    final previous = _last;
    _last = position;

    if (!_jumped) {
      if ((position - _start).abs() > step) {
        _jumped = true;
        _landing = position;
      }
      return false;
    }
    if (position < _landing) {
      _landing = position;
      return false;
    }
    // Une avancée continue, pas un saut : mpv annonce la cible pendant le seek
    // puis la vraie position de la première image, quelques millisecondes plus
    // loin — ce n'est pas encore une lecture.
    final advance = position - previous;
    if (position - _landing >= const Duration(milliseconds: 300) &&
        advance > Duration.zero &&
        advance <= step) {
      notePausedForCache(false);
      _pictureAt ??= _elapsed();
      _resumedAt = _elapsed();
      return true;
    }
    return false;
  }

  /// Une ligne de log. [cacheAhead] est ce que le cache tient devant la tête à
  /// cet instant ; [bitsPerSecond] le débit d'entrée du réseau, s'il est connu.
  String describe({required Duration cacheAhead, int? bitsPerSecond}) {
    String secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
    final now = _elapsed();
    final waited = _cachePaused +
        (_cachePauseSince != null ? now - _cachePauseSince! : Duration.zero);
    final head = resumed
        ? 'reprise +${secs(_resumedAt!)}'
        : 'toujours à l\'arrêt après ${secs(now)}';
    final parts = <String>[
      if (_pictureAt != null) 'image +${secs(_pictureAt!)}',
      head,
      'attente cache ${secs(waited)}'
          '${_cachePauses > 1 ? ' en $_cachePauses fois' : ''}',
      '${cacheAhead.inSeconds}s en mémoire',
      if (bitsPerSecond != null && bitsPerSecond > 0)
        'réseau ${(bitsPerSecond / 1e6).toStringAsFixed(0)} Mbit/s',
    ];
    final target = (this.target.inMilliseconds / 1000).toStringAsFixed(1);
    return 'SEEK mpv → ${target}s : ${parts.join(', ')}';
  }
}
