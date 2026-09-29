import 'dart:async';
import 'dart:math' as math;

/// Une suite d'avances et de reculs à la télécommande, cumulés avant d'être
/// envoyés au lecteur.
///
/// Chaque appui (ou répétition) de gauche/droite déplace [target] et relance
/// un court compte à rebours ; la recherche elle-même n'a lieu qu'une fois les
/// appuis arrêtés. La barre et les temps montrent la cible entre-temps.
/// Chercher à chaque appui calculait chaque pas depuis une position qui
/// n'avait pas encore bougé — dix appuis faisaient dix secondes — et, sur un
/// transcodage, reconstruisait la session à chaque fois.
class RemoteSeek {
  RemoteSeek({required this.onCommit, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Reçoit la cible, en secondes, quand les appuis se sont arrêtés.
  final void Function(int seconds) onCommit;

  final DateTime Function() _clock;

  /// Le temps sans appui au bout duquel la cible est envoyée.
  static const Duration settle = Duration(milliseconds: 650);

  /// Le glissé posé : secondes de film par unité de surface parcourue (la
  /// surface fait 2 unités de large). Un demi-trackpad lent avance de 20 s.
  static const double _scrubSecondsPerUnit = 20;

  /// Au-delà de cette vitesse (unités par seconde), chaque unité parcourue
  /// vaut plus de film, au carré de la vitesse : comme l'accélération d'une
  /// souris, un geste deux fois plus vif va quatre fois plus loin.
  static const double _scrubKneeSpeed = 2;

  double? _target;
  Timer? _commit;
  DateTime? _lastStep;
  int _chain = 0;

  /// Où va la suite d'appuis en cours, en secondes. Nulle hors d'une suite.
  int? get target => _target?.round();

  /// Un pas vers l'avant (`direction` = 1) ou l'arrière (-1).
  ///
  /// Les pas s'enchaînent tant qu'ils arrivent, et une longue suite va plus
  /// vite — 10 s par pas, puis 30 s, puis une minute — pour qu'une touche
  /// maintenue traverse un film en quelques secondes plutôt qu'en quelques
  /// minutes.
  void step(
    int direction, {
    required int fromSeconds,
    required int durationSeconds,
  }) {
    final now = _clock();
    final last = _lastStep;
    final chained = last != null && now.difference(last) < settle;
    _chain = chained ? _chain + 1 : 0;
    _lastStep = now;

    final step = _chain < 10
        ? 10
        : _chain < 30
            ? 30
            : 60;
    _moveTo(
      (_target ?? fromSeconds.toDouble()) + direction * step,
      durationSeconds,
    );
  }

  /// Le doigt a glissé de [travel] unités sur le trackpad de l'Apple TV
  /// (négatif vers la gauche), à [speed] unités par seconde : la cible le
  /// suit, d'autant plus loin qu'il va vite.
  ///
  /// À l'essai, la flèche que le moteur tire d'un glissé valait le même pas
  /// qu'on effleure ou qu'on balaie la surface : la barre n'avançait pas
  /// « suivant le slide ». Ici elle avance avec le doigt, point par point.
  void scrub(
    double travel, {
    required double speed,
    required int fromSeconds,
    required int durationSeconds,
  }) {
    var gain = _scrubSecondsPerUnit *
        math.pow(math.max(1.0, speed / _scrubKneeSpeed), 2);
    // Un unique coup de pouce ne traverse pas plus d'un demi-film par unité.
    if (durationSeconds > 0) {
      gain = math.min(gain, math.max(60.0, durationSeconds / 2));
    }
    _moveTo(
        (_target ?? fromSeconds.toDouble()) + travel * gain, durationSeconds);
  }

  void _moveTo(double target, int durationSeconds) {
    if (target < 0) target = 0;
    if (durationSeconds > 0 && target > durationSeconds) {
      target = durationSeconds.toDouble();
    }
    _target = target;
    _commit?.cancel();
    _commit = Timer(settle, _fire);
  }

  void _fire() {
    final target = this.target;
    if (target == null) return;
    // Les deux chemins de recherche placent la position rapportée sur la
    // cible avant de rendre la main : lâcher la cible après ne fait pas
    // clignoter l'ancien temps.
    onCommit(target);
    _target = null;
    _chain = 0;
  }

  void dispose() => _commit?.cancel();
}
