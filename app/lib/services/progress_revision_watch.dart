import 'dart:async';

/// Suit la progression du compte en direct : sonde le jeton de révision du
/// serveur et prévient quand il a bougé — une série qui avance sur un autre
/// appareil, un épisode coché vu ailleurs.
///
/// Le jeton est sondé plutôt que les données elles-mêmes : relire l'accueil
/// toutes les cinq secondes sur chaque écran allumé coûterait une requête
/// lourde pour, presque toujours, la même réponse.
class ProgressRevisionWatch {
  ProgressRevisionWatch({
    required this.fetch,
    required this.onChanged,
    this.interval = const Duration(seconds: 5),
  });

  /// `ApiClient.getProgressRevision` du serveur courant.
  final Future<String> Function() fetch;
  final void Function() onChanged;
  final Duration interval;

  Timer? _timer;
  String? _last;
  bool _adoptNext = false;
  int _generation = 0;

  /// Sonde tout de suite, puis à chaque [interval].
  ///
  /// Le dernier jeton connu survit à [stop] : un écran qui revient au premier
  /// plan apprend ainsi ce qui a changé pendant qu'on ne le voyait pas.
  /// [adoptFirst] est pour l'écran qui relit déjà ses données à chaque retour :
  /// la première réponse sert alors de point de départ, sans prévenir.
  void start({bool adoptFirst = false}) {
    stop();
    _adoptNext = adoptFirst;
    _timer = Timer.periodic(interval, (_) => unawaited(_check()));
    unawaited(_check());
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    final generation = _generation;
    final String revision;
    try {
      revision = await fetch();
    } catch (_) {
      // Hors ligne, ou serveur d'avant cette route : l'écran garde ce qu'il
      // montre et se relit comme avant, à son retour au premier plan.
      return;
    }
    if (generation != _generation) return;
    final previous = _last;
    _last = revision;
    if (_adoptNext) {
      _adoptNext = false;
      return;
    }
    if (previous != null && previous != revision) onChanged();
  }
}
