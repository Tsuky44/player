import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_platform.dart';
import 'siri_remote_touches.dart';
import 'touchpad_motion.dart';
import 'tv_mode.dart';

/// Le trackpad de la Siri Remote, lu pour sa vitesse (ADR-0039).
///
/// Le moteur de flutter-tvos fait de chaque glissé une flèche : la navigation
/// marche sans rien ici. Ce qui manquait, c'est la force du geste. Effleurer
/// et balayer donnaient la même flèche, donc le même pas d'une affiche, et une
/// rangée de quarante films se traversait à coups de pouce répétés.
///
/// Deux choses changent, et seulement dans ce qui défile (une rangée, une
/// grille, une liste) : dans une barre de boutons ou un menu, un pas reste un
/// pas.
///
/// - **L'accélération.** Une flèche arrivée pendant un glissé vif vaut
///   plusieurs pas ([boostFor]). Le lecteur s'en sert aussi : un coup sec fait
///   avancer le film plus loin.
/// - **L'élan.** Un doigt lâché en pleine vitesse laisse la liste continuer
///   quelques éléments en ralentissant, comme sur l'interface d'Apple. Poser
///   le doigt sur la surface l'arrête net.
///
/// Hors Apple TV, rien de tout cela ne s'installe : [boostFor] vaut toujours 1.
abstract final class TvTouchpad {
  static final TouchpadMotion _motion = TouchpadMotion();
  static final Stopwatch _clock = Stopwatch()..start();
  static bool _installed = false;

  /// Remplace l'horloge dans les tests.
  @visibleForTesting
  static Duration Function()? debugClock;

  static Duration get _now => debugClock?.call() ?? _clock.elapsed;

  /// Premier intervalle de l'élan, puis chaque suivant s'allonge : la liste
  /// ralentit au lieu de s'arrêter d'un coup.
  static const Duration _glideFirstInterval = Duration(milliseconds: 60);
  static const double _glideSlowdown = 1.15;

  /// La flèche du geste lui-même peut arriver juste après que le doigt s'est
  /// levé : elle ne doit pas couper l'élan qu'elle accompagne.
  static const Duration _glideGrace = Duration(milliseconds: 120);

  static Timer? _glideTimer;
  static TraversalDirection? _glideDirection;
  static Duration _glideStartedAt = Duration.zero;
  static int _glideRemaining = 0;
  static Duration _glideInterval = _glideFirstInterval;

  /// Vrai pendant le pas d'élan que ce module est en train de faire : ce pas
  /// n'est pas une flèche, il ne s'accélère pas lui-même.
  static bool _stepping = false;

  /// Vrai tant que la liste avance sur sa lancée. Le défilement suit alors au
  /// plus court, comme pour une flèche maintenue.
  static bool get isGliding => _glideTimer != null;

  /// Branché une fois au démarrage, sur Apple TV seulement.
  static void install() {
    if (_installed || !AppPlatform.isTvOS) return;
    _installed = true;
    listenToSiriRemote(handleTouch);
    HardwareKeyboard.instance.addHandler(_observeKey);
  }

  /// Combien de pas vaut la flèche vers [direction] qui arrive maintenant.
  static int boostFor(TraversalDirection direction) {
    if (_stepping) return 1;
    return _motion.boostFor(direction, _now);
  }

  /// Vrai quand un geste peut accélérer depuis [node] vers [direction] : le
  /// nœud est dans quelque chose qui défile sur cet axe.
  static bool acceleratesFrom(FocusNode node, TraversalDirection direction) {
    final context = node.context;
    if (context == null) return false;
    final axis = switch (direction) {
      TraversalDirection.left || TraversalDirection.right => Axis.horizontal,
      TraversalDirection.up || TraversalDirection.down => Axis.vertical,
    };
    return Scrollable.maybeOf(context, axis: axis) != null;
  }

  /// Un événement du trackpad. Public pour les tests, qui n'ont pas de
  /// Siri Remote.
  @visibleForTesting
  static void handleTouch(TouchpadPhase phase, double x, double y) {
    // Poser le doigt, ou cliquer, arrête la liste là où elle est : c'est le
    // geste que l'Apple TV apprend à ses utilisateurs.
    if (phase == TouchpadPhase.began || phase == TouchpadPhase.clickDown) {
      stopGlide();
    }
    final fling = _motion.add(phase, x, y, _now);
    if (fling != null) _startGlide(fling);
  }

  static void stopGlide() {
    _glideTimer?.cancel();
    _glideTimer = null;
    _glideDirection = null;
    _glideRemaining = 0;
  }

  static void _startGlide(TouchpadFling fling) {
    stopGlide();
    if (!TvMode.isTv) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || !acceleratesFrom(focus, fling.direction)) return;
    _glideDirection = fling.direction;
    _glideRemaining = fling.steps;
    _glideStartedAt = _now;
    _glideInterval = _glideFirstInterval;
    _glideTimer = Timer(_glideInterval, _glideStep);
  }

  static void _glideStep() {
    final direction = _glideDirection;
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (direction == null ||
        focus == null ||
        context == null ||
        !TvMode.isTv ||
        !acceleratesFrom(focus, direction)) {
      stopGlide();
      return;
    }

    _stepping = true;
    try {
      Actions.maybeInvoke<DirectionalFocusIntent>(
        context,
        DirectionalFocusIntent(direction),
      );
    } finally {
      _stepping = false;
    }
    // Le focus demandé ne se pose qu'à la microtâche suivante.
    FocusManager.instance.applyFocusChangesIfNeeded();

    // Le focus n'a pas bougé : bout de la rangée, la lancée s'arrête là.
    _glideRemaining--;
    if (identical(FocusManager.instance.primaryFocus, focus) ||
        _glideRemaining <= 0) {
      stopGlide();
      return;
    }
    _glideInterval = _glideInterval * _glideSlowdown;
    _glideTimer = Timer(_glideInterval, _glideStep);
  }

  /// Toute autre touche reprend la main sur l'élan : OK, Retour, ou une flèche
  /// dans un autre sens.
  static bool _observeKey(KeyEvent event) {
    if (event is! KeyDownEvent || !isGliding) return false;
    final ownArrow = _arrowDirection(event.logicalKey) == _glideDirection &&
        _now - _glideStartedAt < _glideGrace;
    if (!ownArrow) stopGlide();
    return false;
  }

  static TraversalDirection? _arrowDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    return null;
  }

  /// Installe l'observateur de touches hors Apple TV, pour les tests.
  @visibleForTesting
  static void debugInstallKeyObserver() {
    HardwareKeyboard.instance.removeHandler(_observeKey);
    HardwareKeyboard.instance.addHandler(_observeKey);
  }

  @visibleForTesting
  static void debugReset() {
    stopGlide();
    debugClock = null;
    _motion.add(TouchpadPhase.clickUp, 0, 0, Duration.zero);
    _motion.add(TouchpadPhase.ended, 0, 0, Duration.zero);
  }
}
