import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onyx/tv/touchpad_motion.dart';

/// Un glissé horizontal de [distance] unités en [duration], échantillonné
/// toutes les 16 ms comme le rapporte le moteur.
Duration swipe(
  TouchpadMotion motion, {
  required double distance,
  required Duration duration,
  Duration start = Duration.zero,
  bool vertical = false,
}) {
  motion.add(TouchpadPhase.began, 0, 0, start);
  final frames = (duration.inMilliseconds / 16).ceil();
  var at = start;
  for (var i = 1; i <= frames; i++) {
    at = start + Duration(milliseconds: 16 * i);
    final travelled = distance * i / frames;
    motion.add(
      TouchpadPhase.moved,
      vertical ? 0 : travelled,
      vertical ? travelled : 0,
      at,
    );
  }
  return at;
}

void main() {
  const ms = Duration(milliseconds: 1);

  group('accélération', () {
    test('un glissé posé vaut un seul pas', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 0.6, duration: ms * 300);
      expect(motion.boostFor(TraversalDirection.right, at), 1);
    });

    test('un glissé franc vaut deux pas', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 1.4, duration: ms * 112);
      expect(motion.boostFor(TraversalDirection.right, at), 2);
    });

    test('seul un vrai coup sec vaut trois pas, jamais plus', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 4, duration: ms * 112);
      expect(motion.boostFor(TraversalDirection.right, at), 3);
    });

    test('la vitesse ne compte que dans le sens de la flèche', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      expect(motion.boostFor(TraversalDirection.left, at), 1);
      expect(motion.boostFor(TraversalDirection.down, at), 1);
    });

    test('un glissé vertical accélère haut et bas, y vers le bas', () {
      final motion = TouchpadMotion();
      final at = swipe(
        motion,
        distance: -2.0,
        duration: ms * 112,
        vertical: true,
      );
      expect(motion.boostFor(TraversalDirection.up, at), 3);
      expect(motion.boostFor(TraversalDirection.down, at), 1);
    });

    test('un doigt arrêté ne donne plus d’élan aux flèches suivantes', () {
      // Le pavé directionnel ou une manette, juste après un glissé.
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      expect(motion.boostFor(TraversalDirection.right, at + ms * 200), 1);
    });

    test('un clic sur le pavé n’est jamais accéléré', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      motion.add(TouchpadPhase.clickDown, 2.0, 0, at);
      expect(motion.boostFor(TraversalDirection.right, at), 1);
    });

    test('sans trackpad, une flèche vaut un pas', () {
      expect(
        TouchpadMotion().boostFor(TraversalDirection.right, Duration.zero),
        1,
      );
    });
  });

  group('glissé en cours', () {
    test('le doigt qui glisse est vu comme tel, puis plus', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 0.6, duration: ms * 300);
      expect(motion.swipingAt(at), isTrue);
      expect(motion.swipingAt(at + ms * 200), isFalse);
    });

    test('un clic n’est pas un glissé', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 0.6, duration: ms * 300);
      motion.add(TouchpadPhase.clickDown, 0.6, 0, at);
      expect(motion.swipingAt(at), isFalse);
      expect(motion.lastMove, isNull);
    });

    test('chaque déplacement donne son pas et la vitesse du doigt', () {
      final motion = TouchpadMotion();
      swipe(motion, distance: 2.0, duration: ms * 112);
      final move = motion.lastMove!;
      expect(move.dx, closeTo(2.0 / 7, 1e-9));
      expect(move.speed, greaterThan(15));
    });
  });

  group('élan', () {
    test('un geste lâché en pleine vitesse continue sur sa lancée', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      final fling = motion.add(TouchpadPhase.ended, 2.0, 0, at);
      expect(fling, isNotNull);
      expect(fling!.direction, TraversalDirection.right);
      expect(fling.steps, greaterThan(1));
    });

    test('plus le geste est vif, plus il va loin, jusqu’à un plafond', () {
      int stepsFor(double distance) {
        final motion = TouchpadMotion();
        final at = swipe(motion, distance: distance, duration: ms * 96);
        return motion.add(TouchpadPhase.ended, distance, 0, at)!.steps;
      }

      expect(stepsFor(1.2), lessThan(stepsFor(1.8)));
      expect(stepsFor(20), 6);
    });

    test('un glissé posé s’arrête quand le doigt se lève', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 0.6, duration: ms * 300);
      expect(motion.add(TouchpadPhase.ended, 0.6, 0, at), isNull);
    });

    test('un doigt qui s’immobilise avant de se lever n’a plus d’élan', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      expect(motion.add(TouchpadPhase.ended, 2.0, 0, at + ms * 300), isNull);
    });

    test('un clic en cours de geste annule l’élan', () {
      final motion = TouchpadMotion();
      final at = swipe(motion, distance: 2.0, duration: ms * 112);
      motion.add(TouchpadPhase.clickDown, 2.0, 0, at);
      expect(motion.add(TouchpadPhase.ended, 2.0, 0, at), isNull);
    });
  });
}
