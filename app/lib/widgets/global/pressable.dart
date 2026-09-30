import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';

/// L'état d'appui d'une carte de contenu, et l'échelle qui va avec.
///
/// Le retour arrive au `pointer-down`, pas au relâchement : avant, une affiche
/// ne répondait qu'au survol — donc jamais au doigt — et la vignette
/// « Reprendre la lecture » ne répondait à rien du tout avant que la page ne
/// s'ouvre. Pas d'ondulation : elle se propage depuis le doigt en une
/// fraction de seconde, là où l'échelle est là dès le premier contact.
///
/// L'appui passe par le recognizer de tap et non par un `Listener` : dans une
/// rangée qui défile, le tap perd l'arène dès que le doigt glisse, ce qui
/// déclenche `onTapCancel` et rend l'échelle. Un `Listener` laisserait la carte
/// rétrécie pendant tout le défilement.
///
/// [builder] reçoit l'état d'appui pour que la carte choisisse ce qui rétrécit
/// — l'affiche, pas les lignes de texte dessous, qui tremblotent à 0,97.
/// [PressScale] fait ce travail pour le cas courant.
class Pressable extends StatefulWidget {
  final VoidCallback? onTap;

  /// Le premier signal d'intention au doigt, quelques centaines de
  /// millisecondes avant le tap confirmé — le moment de préchauffer.
  final VoidCallback? onTapDown;
  final Widget Function(BuildContext context, bool pressed) builder;

  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.onTapDown,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: widget.onTap == null
            ? null
            : (_) {
                _setPressed(true);
                widget.onTapDown?.call();
              },
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: widget.builder(context, _pressed),
      ),
    );
  }
}

/// L'échelle d'appui des cartes : [AppMotion.pressScale], ramenée à rien sous
/// « réduire les animations » puisque c'est de la géométrie.
class PressScale extends StatelessWidget {
  final bool pressed;
  final Widget child;

  const PressScale({super.key, required this.pressed, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: pressed ? AppMotion.pressScale : 1.0,
      duration: AppMotion.move(context, AppMotion.micro),
      curve: AppMotion.curve,
      child: child,
    );
  }
}
