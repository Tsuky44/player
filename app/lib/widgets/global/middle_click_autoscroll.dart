import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/app_colors.dart';

/// Défilement automatique au clic molette, comme dans un navigateur sous
/// Windows : un clic molette pose une ancre, et la page défile d'autant plus
/// vite que la souris s'en éloigne.
///
/// Deux façons de s'en servir, comme ailleurs :
/// - cliquer puis lâcher : le défilement continue jusqu'au clic suivant ;
/// - garder la molette enfoncée et tirer : il s'arrête au relâchement.
///
/// Chaque zone défilante est enveloppée par [AppScrollBehavior], si bien que
/// le clic atteint toutes celles qui sont sous la souris, de la plus profonde à
/// la page. La plus profonde qui peut défiler dans un axe le prend : sur
/// l'accueil, une rangée d'affiches suit la souris à l'horizontale et la page à
/// la verticale.
class MiddleClickAutoScroll extends StatelessWidget {
  const MiddleClickAutoScroll({
    super.key,
    required this.details,
    required this.child,
  });

  final ScrollableDetails details;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = details.controller;
    // Une PageView tourne des pages : la faire glisser à vitesse continue la
    // laisserait entre deux.
    if (controller == null || controller is PageController) return child;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse ||
            event.buttons & kMiddleMouseButton == 0) {
          return;
        }
        _AutoScrollSession.claim(
          context,
          event,
          controller,
          details.direction,
        );
      },
      child: child,
    );
  }
}

class _AutoScrollTarget {
  _AutoScrollTarget(this.controller, this.direction);

  final ScrollController controller;
  final AxisDirection direction;

  Axis get axis => axisDirectionToAxis(direction);
}

/// Une séance de défilement automatique, du clic molette qui la lance au clic
/// qui l'arrête. Il n'y en a qu'une à la fois.
class _AutoScrollSession {
  _AutoScrollSession._(this._startEvent, this._anchor) : _pointer = _anchor;

  static _AutoScrollSession? _current;

  /// Sous ce rayon autour de l'ancre, rien ne bouge : une main ne tient pas une
  /// souris au pixel près.
  static const double _deadZone = 12;

  /// Au-delà de cette distance, ou de cette durée, le relâchement de la molette
  /// arrête la séance : c'était un glisser, pas un clic.
  static const double _dragDistance = 20;
  static const Duration _holdDuration = Duration(milliseconds: 350);

  final PointerDownEvent _startEvent;
  final Offset _anchor;
  // L'ancre dans le repère de l'overlay, qui ne commence pas en haut de la
  // fenêtre quand la barre de titre Windows est affichée.
  Offset _overlayAnchor = Offset.zero;
  Offset _pointer;
  bool _dragged = false;
  final Map<Axis, _AutoScrollTarget> _targets = {};
  final Stopwatch _clock = Stopwatch()..start();
  Duration? _lastFrame;
  OverlayEntry? _overlay;
  bool _stopped = false;

  /// Appelé par chaque zone défilante sous la souris, de la plus profonde à la
  /// plus haute, pour le même événement.
  static void claim(
    BuildContext context,
    PointerDownEvent event,
    ScrollController controller,
    AxisDirection direction,
  ) {
    // Each listener gets the event transformed into its own coordinates, as a
    // copy: the one that started the session is recognised by its original.
    final original = event.original as PointerDownEvent? ?? event;
    var session = _current;
    if (session != null && !identical(session._startEvent, original)) {
      // Un clic molette pendant une séance l'arrête, comme dans un navigateur.
      session.stop();
      return;
    }
    if (session == null) {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      session = _AutoScrollSession._(original, original.position);
      _current = session;
      session._begin(overlay);
    }
    session._claim(controller, direction);
  }

  void _claim(ScrollController controller, AxisDirection direction) {
    final target = _AutoScrollTarget(controller, direction);
    if (_targets.containsKey(target.axis) || !controller.hasClients) return;
    if (controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }
    _targets[target.axis] = target;
  }

  void _begin(OverlayState overlay) {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalEvent);
    final box = overlay.context.findRenderObject() as RenderBox?;
    _overlayAnchor = box?.globalToLocal(_anchor) ?? _anchor;
    _overlay = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlay!);
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  void _handleGlobalEvent(PointerEvent event) {
    if (_stopped) return;
    if (identical(event.original ?? event, _startEvent)) {
      // Le clic est passé par toutes les zones sous la souris : si aucune ne
      // pouvait défiler, il n'y a rien à faire.
      if (_targets.isEmpty) stop();
      return;
    }
    if (event.kind != PointerDeviceKind.mouse) return;

    if (event is PointerHoverEvent || event is PointerMoveEvent) {
      _pointer = event.position;
      if ((_pointer - _anchor).distance > _dragDistance) _dragged = true;
    } else if (event is PointerUpEvent &&
        event.pointer == _startEvent.pointer) {
      if (_dragged || _clock.elapsed > _holdDuration) stop();
    }
  }

  void _tick(Duration timestamp) {
    if (_stopped) return;
    final last = _lastFrame;
    _lastFrame = timestamp;
    if (last != null) {
      final seconds = (timestamp - last).inMicroseconds / 1e6;
      final offset = _pointer - _anchor;
      for (final target in _targets.values) {
        final controller = target.controller;
        if (!controller.hasClients || controller.positions.length != 1) {
          continue;
        }
        final distance = target.axis == Axis.vertical ? offset.dy : offset.dx;
        var delta = _speedFor(distance) * seconds;
        if (axisDirectionIsReversed(target.direction)) delta = -delta;
        if (delta != 0) controller.position.pointerScroll(delta);
      }
    }
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  /// Pixels par seconde pour une souris à [distance] de l'ancre : lent près
  /// d'elle, pour lire, et vite quand on s'en éloigne, pour traverser une
  /// longue liste.
  static double _speedFor(double distance) {
    final excess = distance.abs() - _deadZone;
    if (excess <= 0) return 0;
    return distance.sign * math.pow(excess / 10, 1.6) * 20;
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handleGlobalEvent);
    _overlay?.remove();
    _overlay = null;
    if (identical(_current, this)) _current = null;
  }

  Widget _buildOverlay(BuildContext context) {
    final vertical = _targets.containsKey(Axis.vertical);
    final horizontal = _targets.containsKey(Axis.horizontal);
    final icon = vertical && horizontal
        ? Icons.open_with_rounded
        : Icons.unfold_more_rounded;

    // Plein écran et opaque : le clic qui arrête la séance ne doit pas aussi
    // ouvrir l'affiche qui se trouve dessous, et la molette l'arrête aussi.
    return Positioned.fill(
      child: MouseRegion(
        cursor: SystemMouseCursors.allScroll,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => stop(),
          onPointerSignal: (_) => stop(),
          child: Stack(
            children: [
              Positioned(
                left: _overlayAnchor.dx - 16,
                top: _overlayAnchor.dy - 16,
                child: IgnorePointer(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.surface.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                    child: RotatedBox(
                      quarterTurns: horizontal && !vertical ? 1 : 0,
                      child: Icon(icon, size: 20, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
