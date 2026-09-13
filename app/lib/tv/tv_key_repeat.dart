import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'tv_mode.dart';

/// Ce que la télécommande fait quand on laisse une flèche enfoncée.
///
/// Android répète une touche maintenue toutes les 50 ms environ. Chaque
/// répétition déplaçait le focus d'une carte et relançait le défilement animé
/// qui la ramène à l'écran ; au bout de quelques cartes, le focus courait devant
/// une rangée qui n'avait pas fini de défiler, arrivait sur des cartes pas encore
/// construites, et s'arrêtait net — la rangée « bloquait » au milieu. Leanback,
/// sur lequel repose Jellyfin, régule ce débit ; Flutter ne le fait pas.
///
/// On observe donc les touches avant le système de focus pour savoir si la flèche
/// en cours est une répétition, et [TvDirectionalFocusAction] laisse passer au
/// plus un déplacement par [repeatInterval] tant qu'elle l'est. Un appui simple
/// n'est jamais retenu.
abstract final class TvKeyRepeat {
  /// Assez lent pour que la carte suivante soit construite et à l'écran, assez
  /// rapide pour qu'une longue rangée se parcoure d'un seul geste.
  static const Duration repeatInterval = Duration(milliseconds: 110);

  static bool _installed = false;
  static bool _repeating = false;

  /// Vrai tant que la dernière flèche reçue est une répétition automatique.
  static bool get isRepeating => _repeating;

  static final Set<LogicalKeyboardKey> _arrows = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  /// Branché une fois au démarrage. Le gestionnaire ne consomme jamais rien :
  /// il regarde passer les touches, il ne les retient pas.
  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_observe);
  }

  static bool _observe(KeyEvent event) {
    if (_arrows.contains(event.logicalKey)) {
      _repeating = event is KeyRepeatEvent;
    }
    return false;
  }

  @visibleForTesting
  static void debugReset() {
    _repeating = false;
    TvDirectionalFocusAction._lastMove = null;
  }
}

/// Le déplacement du focus aux flèches, sur un téléviseur.
///
/// Remplace [DirectionalFocusAction] à la racine de l'app. Deux différences, et
/// hors téléviseur aucune :
///
/// - la flèche maintenue est régulée, voir [TvKeyRepeat] ;
/// - gauche et droite ne quittent jamais la ligne. Au bout d'une rangée ou
///   d'une ligne de grille, Flutter cherche « quelque chose à droite » n'importe
///   où sur l'écran : l'avatar du compte dans l'en-tête, une affiche d'une autre
///   rangée qui dépasse plus loin. Le focus sautait alors à l'autre bout de
///   l'écran, et l'on ne savait plus où l'on était. Ici, sans rien sur la même
///   ligne, le focus reste où il est — comme sur Jellyfin.
class TvDirectionalFocusAction extends DirectionalFocusAction {
  TvDirectionalFocusAction();

  static DateTime? _lastMove;

  @override
  void invoke(DirectionalFocusIntent intent) {
    if (!TvMode.isTv) {
      _lastMove = DateTime.now();
      super.invoke(intent);
      return;
    }
    if (TvKeyRepeat.isRepeating) {
      final now = DateTime.now();
      final last = _lastMove;
      if (last != null && now.difference(last) < TvKeyRepeat.repeatInterval) {
        return;
      }
      _lastMove = now;
    } else {
      _lastMove = DateTime.now();
    }

    final direction = intent.direction;
    final current = primaryFocus;
    if (current == null ||
        current.context == null ||
        current is FocusScopeNode ||
        (direction != TraversalDirection.left &&
            direction != TraversalDirection.right)) {
      super.invoke(intent);
      return;
    }

    final target = nextOnLine(current, direction);
    if (target == null) return;
    target.requestFocus();
    Scrollable.ensureVisible(
      target.context!,
      alignmentPolicy: direction == TraversalDirection.left
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  /// Le voisin le plus proche de [current] dans [direction], parmi ce qui
  /// partage sa ligne — ce qui chevauche verticalement sa hauteur. Nul quand il
  /// n'y en a pas.
  @visibleForTesting
  static FocusNode? nextOnLine(FocusNode current, TraversalDirection direction) {
    final scope = current.nearestScope;
    if (scope == null) return null;
    final from = current.rect;
    final right = direction == TraversalDirection.right;

    final candidates = scope.traversalDescendants.where((node) {
      if (identical(node, current) || node.context == null) return false;
      final rect = node.rect;
      if (rect.isEmpty) return false;
      // Même règle que Flutter pour « à droite de » / « à gauche de ».
      final beyond = right
          ? rect.center.dx >= from.right
          : rect.center.dx <= from.left;
      return beyond && rect.top < from.bottom && rect.bottom > from.top;
    }).toList();
    if (candidates.isEmpty) return null;

    // Ce qui défile avec l'élément d'abord : dans une rangée, la carte
    // suivante, et pas un bouton posé à côté de la rangée.
    final scrollable = Scrollable.maybeOf(current.context!, axis: Axis.horizontal);
    if (scrollable != null) {
      final sameScrollable = candidates
          .where((node) =>
              Scrollable.maybeOf(node.context!, axis: Axis.horizontal) ==
              scrollable)
          .toList();
      if (sameScrollable.isNotEmpty) {
        candidates
          ..clear()
          ..addAll(sameScrollable);
      }
    }

    double distance(FocusNode node) {
      final rect = node.rect;
      final dx = right ? rect.left - from.right : from.left - rect.right;
      final dy = (rect.center.dy - from.center.dy).abs();
      // L'écart horizontal d'abord ; à égalité, le mieux aligné.
      return dx.abs() * 1000 + dy;
    }

    candidates.sort((a, b) => distance(a).compareTo(distance(b)));
    return candidates.first;
  }
}
