import 'dart:async';

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

  int? _target;
  Timer? _commit;
  DateTime? _lastStep;
  int _chain = 0;

  /// Où va la suite d'appuis en cours, en secondes. Nulle hors d'une suite.
  int? get target => _target;

  /// Un pas vers l'avant (`direction` = 1) ou l'arrière (-1).
  ///
  /// Les pas s'enchaînent tant qu'ils arrivent, et une longue suite va plus
  /// vite — 10 s par pas, puis 30 s, puis une minute — pour qu'une touche
  /// maintenue traverse un film en quelques secondes plutôt qu'en quelques
  /// minutes. [boost] multiplie le pas : un glissé vif sur le trackpad de
  /// l'Apple TV va plus loin qu'un glissé posé (voir `TvTouchpad`).
  void step(
    int direction, {
    required int fromSeconds,
    required int durationSeconds,
    int boost = 1,
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
    var target = (_target ?? fromSeconds) + direction * step * boost;
    if (target < 0) target = 0;
    if (durationSeconds > 0 && target > durationSeconds) {
      target = durationSeconds;
    }

    _target = target;
    _commit?.cancel();
    _commit = Timer(settle, _fire);
  }

  void _fire() {
    final target = _target;
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
