/// Les étapes d'un démarrage, écrites en une ligne quand l'image est à l'écran.
///
/// « Ça met du temps à démarrer » ne s'attribue pas autrement : l'attente se
/// partage entre le ticket, la reprise, l'ouverture du flux par le moteur, le
/// chargement du fichier et la première image, et seul le découpage dit
/// laquelle viser. La ligne nomme donc aussi l'étape la plus longue.
class StartupTimeline {
  /// [elapsed] remplace le chronomètre, pour les tests.
  StartupTimeline({Duration Function()? elapsed}) : _clock = elapsed;

  final Duration Function()? _clock;
  final Stopwatch _watch = Stopwatch();
  final List<({String label, int millis})> _marks = [];
  bool _started = false;
  bool _closed = false;
  int? _playingMillis;
  String? _note;

  Duration get _elapsed => _clock?.call() ?? _watch.elapsed;

  bool get isRunning => _started && !_closed;

  void start() {
    if (_started) return;
    _started = true;
    _watch.start();
  }

  /// Retient la première occurrence de [label] ; les suivantes sont ignorées,
  /// pour qu'une étape portée par un flux se marque depuis un écouteur qui
  /// tire plusieurs fois.
  void mark(String label) {
    if (!isRunning) return;
    if (_marks.any((m) => m.label == label)) return;
    _marks.add((label: label, millis: _elapsed.inMilliseconds));
  }

  /// Un détail qui change la lecture des chiffres, comme le point de reprise.
  void note(String text) => _note = _note == null ? text : '$_note · $text';

  /// Marque `playing` — l'horloge tourne — et rend la durée du démarrage, une
  /// seule fois ; null ensuite.
  ///
  /// Ne clôt pas : la première image peinte vient après, et c'est elle que
  /// l'utilisateur attend. L'ancienne version clôturait avant de marquer, et
  /// la ligne s'arrêtait à `play=`, sans le total — celui qu'on vient lire.
  int? notePlaying() {
    if (!isRunning || _playingMillis != null) return null;
    mark('playing');
    return _playingMillis = _elapsed.inMilliseconds;
  }

  /// Clôt et rend la ligne, une seule fois ; null ensuite ou jamais ouvert.
  ///
  /// [complete] à faux pour un démarrage abandonné : c'est justement celui
  /// qu'on veut pouvoir relire, étape par étape, jusqu'à celle qui n'est pas
  /// venue.
  String? close({bool complete = true}) {
    if (!isRunning) return null;
    _closed = true;
    _watch.stop();
    return describe(complete: complete);
  }

  String describe({bool complete = true}) {
    final buffer = StringBuffer(
        complete ? 'PLAYER STARTUP:' : 'PLAYER STARTUP (inachevé):');
    for (final m in _marks) {
      buffer.write(' ${m.label}=${m.millis}ms');
    }
    final slowest = _slowestStep();
    if (slowest != null) buffer.write(' · plus long : $slowest');
    if (!complete) {
      buffer.write(' · abandonné à ${_elapsed.inMilliseconds}ms');
    }
    if (_note != null) buffer.write(' · $_note');
    return buffer.toString();
  }

  /// `play→loaded +9100ms` : l'écart le plus grand entre deux étapes voisines.
  String? _slowestStep() {
    if (_marks.length < 2) return null;
    var from = 0;
    var gap = -1;
    for (var i = 1; i < _marks.length; i++) {
      final step = _marks[i].millis - _marks[i - 1].millis;
      if (step > gap) {
        gap = step;
        from = i - 1;
      }
    }
    return '${_marks[from].label}→${_marks[from + 1].label} +${gap}ms';
  }
}
