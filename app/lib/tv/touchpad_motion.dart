import 'package:flutter/widgets.dart' show TraversalDirection;

/// Ce que la surface tactile de la Siri Remote raconte, réduit à ce qui sert.
enum TouchpadPhase { began, moved, ended, clickDown, clickUp }

/// Un geste lâché avec de l'élan : combien d'éléments il doit encore parcourir,
/// et dans quel sens.
typedef TouchpadFling = ({TraversalDirection direction, int steps});

/// La vitesse du doigt sur le trackpad, et ce qu'elle vaut en navigation.
///
/// Le moteur de flutter-tvos traduit déjà chaque glissé en flèche, mais une
/// flèche est la même que le doigt ait effleuré la surface ou l'ait balayée
/// d'un coup sec. Ce modèle rend cette différence : il garde les derniers
/// points du doigt et répond à deux questions.
///
/// - [boostFor] : la flèche qui arrive maintenant vaut combien de pas ? Un
///   pour un geste posé, jusqu'à [_boostSpeeds].length + 1 pour un geste vif.
/// - [add] en fin de geste : le doigt est-il parti avec de l'élan ? Si oui,
///   combien d'éléments la liste doit encore parcourir sur sa lancée.
///
/// Les coordonnées sont celles du moteur : normalisées dans `[-1, 1]`, y vers
/// le bas. Aucune dépendance au temps réel : l'horloge est passée à chaque
/// appel, ce qui rend le modèle testable à la milliseconde.
///
/// Les seuils sont des estimations, pas des mesures : ils se règlent sur une
/// vraie Apple TV (voir ADR-0039).
class TouchpadMotion {
  /// La fenêtre sur laquelle la vitesse est mesurée. Plus courte, un seul
  /// échantillon bruité fait la vitesse ; plus longue, un geste qui ralentit
  /// garde la vitesse de son début.
  static const Duration _window = Duration(milliseconds: 100);

  /// Au-delà, le doigt s'est arrêté (ou a quitté la surface) : la flèche qui
  /// arrive ne vient plus d'un glissé, elle vient du pavé directionnel ou d'un
  /// autre appareil.
  static const Duration _stale = Duration(milliseconds: 150);

  /// Vitesses, en unités de surface par seconde, à partir desquelles une flèche
  /// vaut 2, 3 puis 4 pas. Un glissé posé fait 2 à 3 u/s, un coup sec 10 et
  /// plus.
  static const List<double> _boostSpeeds = <double>[4, 7, 10];

  /// Vitesse de lâcher à partir de laquelle le geste continue sur sa lancée, et
  /// ce que coûte chaque pas d'élan supplémentaire.
  static const double _flingSpeed = 6;
  static const double _flingSpeedPerStep = 1.5;

  /// Une longue rangée se traverse d'un coup sec, sans que le focus parte à
  /// l'autre bout d'un catalogue entier.
  static const int _maxFlingSteps = 12;

  final List<({double x, double y, Duration at})> _samples =
      <({double x, double y, Duration at})>[];
  bool _clicking = false;

  /// Ajoute un événement du trackpad. Renvoie l'élan du geste quand il se
  /// termine lancé, nul sinon.
  TouchpadFling? add(TouchpadPhase phase, double x, double y, Duration at) {
    switch (phase) {
      case TouchpadPhase.began:
        _samples
          ..clear()
          ..add((x: x, y: y, at: at));
        return null;
      case TouchpadPhase.moved:
        _samples.add((x: x, y: y, at: at));
        _samples.removeWhere((s) => at - s.at > _window * 2);
        return null;
      case TouchpadPhase.clickDown:
        _clicking = true;
        return null;
      case TouchpadPhase.clickUp:
        _clicking = false;
        return null;
      case TouchpadPhase.ended:
        final fling = _clicking ? null : _flingAt(at);
        _samples.clear();
        return fling;
    }
  }

  /// Combien de pas vaut une flèche vers [direction] reçue à [now].
  ///
  /// Un seul, sauf quand le doigt glisse en ce moment même dans ce sens-là :
  /// une flèche du pavé directionnel, d'une manette ou de l'app Remote de
  /// l'iPhone n'est jamais accélérée.
  int boostFor(TraversalDirection direction, Duration now) {
    if (_clicking) return 1;
    final velocity = _velocityAt(now);
    if (velocity == null) return 1;
    final speed = switch (direction) {
      TraversalDirection.right => velocity.dx,
      TraversalDirection.left => -velocity.dx,
      TraversalDirection.down => velocity.dy,
      TraversalDirection.up => -velocity.dy,
    };
    var steps = 1;
    for (final threshold in _boostSpeeds) {
      if (speed >= threshold) steps++;
    }
    return steps;
  }

  TouchpadFling? _flingAt(Duration at) {
    final velocity = _velocityAt(at);
    if (velocity == null) return null;
    final horizontal = velocity.dx.abs() >= velocity.dy.abs();
    final speed = horizontal ? velocity.dx.abs() : velocity.dy.abs();
    if (speed < _flingSpeed) return null;
    final steps = ((speed - _flingSpeed) / _flingSpeedPerStep).floor() + 1;
    final TraversalDirection direction;
    if (horizontal) {
      direction =
          velocity.dx > 0 ? TraversalDirection.right : TraversalDirection.left;
    } else {
      direction =
          velocity.dy > 0 ? TraversalDirection.down : TraversalDirection.up;
    }
    return (direction: direction, steps: steps.clamp(1, _maxFlingSteps));
  }

  /// La vitesse moyenne sur la dernière [_window] de mouvement, en unités par
  /// seconde. Nulle quand le doigt est immobile depuis [_stale] ou qu'il n'y a
  /// pas deux points à comparer.
  ({double dx, double dy})? _velocityAt(Duration now) {
    if (_samples.length < 2) return null;
    final last = _samples.last;
    if (now - last.at > _stale) return null;
    final first = _samples.firstWhere(
      (s) => last.at - s.at <= _window,
      orElse: () => last,
    );
    final elapsed = (last.at - first.at).inMicroseconds / 1e6;
    // Deux points arrivés ensemble ne disent rien de la vitesse.
    if (elapsed < 0.008) return null;
    return (
      dx: (last.x - first.x) / elapsed,
      dy: (last.y - first.y) / elapsed,
    );
  }
}
