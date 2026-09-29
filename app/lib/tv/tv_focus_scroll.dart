import 'package:flutter/widgets.dart';

import '../theme/app_motion.dart';
import 'tv_key_repeat.dart';
import 'tv_mode.dart';
import 'tv_touchpad.dart';

/// Le défilement qui ramène à l'écran ce que la télécommande vient d'atteindre.
///
/// Il y en avait deux par pas. Le parcours directionnel de Flutter demande le
/// focus puis *saute* (durée nulle) juste assez pour montrer la cible au bord
/// de l'écran ; à la frame suivante, [TvFocusable] l'anime jusqu'au centre. Le
/// résultat était un à-coup à chaque flèche : la rangée bondissait, puis
/// glissait, et l'œil perdait l'affiche qu'il suivait.
///
/// Désormais un seul défilement par pas, et toujours animé : celui de
/// [TvFocusable] quand la cible en est un (il sait où la placer), celui-ci
/// sinon. Hors téléviseur, le comportement de Flutter est inchangé.
abstract final class TvFocusScroll {
  /// Compté plutôt que booléen : un même nœud passe parfois d'une rangée à
  /// l'autre (le menu des réglages du lecteur), et la nouvelle le déclare
  /// avant que l'ancienne ne l'oublie.
  static final Expando<int> _selfScrolling = Expando<int>('tv-self-scroll');

  /// Déclare que [node] se ramène lui-même à l'écran quand il prend le focus.
  /// Chaque appel est rendu par un [forgetSelfScrolling].
  static void markSelfScrolling(FocusNode node) {
    _selfScrolling[node] = (_selfScrolling[node] ?? 0) + 1;
  }

  static void forgetSelfScrolling(FocusNode node) {
    final count = (_selfScrolling[node] ?? 0) - 1;
    _selfScrolling[node] = count > 0 ? count : null;
  }

  static bool scrollsItself(FocusNode node) => (_selfScrolling[node] ?? 0) > 0;

  /// La durée d'un défilement de focus. Au plus court quand les pas se
  /// suivent (flèche maintenue, élan du trackpad) : l'animation doit finir
  /// avant le pas suivant.
  static Duration durationFor(BuildContext context) => AppMotion.move(
        context,
        TvKeyRepeat.isRepeating || TvTouchpad.isGliding
            ? AppMotion.track
            : AppMotion.standard,
      );

  /// Le [TraversalRequestFocusCallback] de l'app : la politique de parcours
  /// l'appelle à chaque déplacement aux flèches.
  static void requestFocus(
    FocusNode node, {
    ScrollPositionAlignmentPolicy? alignmentPolicy,
    double? alignment,
    Duration? duration,
    Curve? curve,
  }) {
    if (!TvMode.isTv) {
      FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
        node,
        alignmentPolicy: alignmentPolicy,
        alignment: alignment,
        duration: duration,
        curve: curve,
      );
      return;
    }
    node.requestFocus();
    final context = node.context;
    if (context == null || scrollsItself(node)) return;
    Scrollable.ensureVisible(
      context,
      alignment: alignment ?? 1,
      alignmentPolicy:
          alignmentPolicy ?? ScrollPositionAlignmentPolicy.explicit,
      duration: duration ?? durationFor(context),
      curve: curve ?? AppMotion.curve,
    );
  }
}
