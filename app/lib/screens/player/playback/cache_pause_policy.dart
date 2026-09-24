/// Combien de secondes mpv doit avoir en mémoire avant de repartir.
///
/// C'est `cache-pause-wait`, la même valeur pour une reprise après un seek et
/// pour une reprise après une coupure. Une valeur fixe est fausse dans les deux
/// sens : trop grande, un réseau qui suit fait attendre pour rien ; trop petite,
/// un réseau plus lent que le débit du film repart, lit trois secondes, recoupe,
/// et l'image avance par à-coups — image, blocage, image.
///
/// La politique part donc court et n'allonge l'attente que sur preuve : deux
/// coupures rapprochées disent que la connexion ne tient pas le débit, et
/// qu'attendre davantage une fois vaut mieux que de bloquer toutes les dix
/// secondes. Après un moment sans coupure, elle revient au départ — sans quoi un
/// accroc passager ferait attendre vingt secondes à chaque seek du film.
class CachePausePolicy {
  CachePausePolicy({
    this.levels = const [2, 5, 10, 20],
    this.escalationWindow = const Duration(minutes: 2),
    this.calmPeriod = const Duration(minutes: 3),
  }) : assert(levels.isNotEmpty);

  /// Les attentes successives, en secondes de média.
  final List<int> levels;

  /// Deux coupures plus rapprochées que ça allongent l'attente.
  final Duration escalationWindow;

  /// Sans coupure pendant ça, l'attente revient au départ.
  final Duration calmPeriod;

  int _level = 0;
  DateTime? _lastUnderrun;

  int get waitSeconds => levels[_level];

  /// Après un changement de piste, le cache vide est le rechargement de la
  /// nouvelle piste.
  static const trackSwitchGrace = Duration(seconds: 10);

  /// Vrai quand une mise en pause du cache, commencée à [pausedAt], accuse la
  /// réception — hors changement de piste, toujours.
  ///
  /// mpv ne se met en pause que quand un décodeur réclame un paquet que le
  /// démultiplexeur n'a pas. Un décodage lent ne vide pas le cache, il le
  /// laisse grossir. Avec quatre minutes de lecture anticipée, un cache vide en
  /// pleine lecture dit donc que le débit reçu en moyenne est passé sous celui
  /// du film, quelle que soit la vitesse de la reprise qui suit.
  ///
  /// Le critère était cette vitesse : une pause plus courte que [waitSeconds]
  /// innocentait le réseau. Elle ne mesure qu'une rafale. Sur un lien en dents
  /// de scie, ce critère a absous quatre coupures en une minute (« 5 s
  /// regarnies en 1,81 s ») et laissé l'attente à son minimum pendant que le
  /// film se coupait.
  bool blamesNetwork(DateTime pausedAt, {DateTime? lastTrackSwitch}) =>
      lastTrackSwitch == null ||
      pausedAt.difference(lastTrackSwitch) > trackSwitchGrace;

  /// Une coupure en pleine lecture. Renvoie `true` si l'attente a changé.
  bool noteUnderrun(DateTime now) {
    final before = _level;
    final last = _lastUnderrun;
    _lastUnderrun = now;
    if (last == null || now.difference(last) > calmPeriod) {
      _level = 0;
    } else if (now.difference(last) <= escalationWindow &&
        _level < levels.length - 1) {
      _level++;
    }
    return _level != before;
  }

  /// À consulter avant un seek : la reprise qui suit attend [waitSeconds].
  /// Renvoie `true` si l'attente est revenue au départ.
  bool relaxIfCalm(DateTime now) {
    final last = _lastUnderrun;
    if (_level == 0 || last == null) return false;
    if (now.difference(last) <= calmPeriod) return false;
    _level = 0;
    return true;
  }

  void reset() {
    _level = 0;
    _lastUnderrun = null;
  }
}
