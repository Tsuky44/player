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

/// Le déplacement du focus aux flèches, régulé quand la touche est maintenue.
///
/// Remplace [DirectionalFocusAction] à la racine de l'app. Hors téléviseur, il
/// se comporte exactement comme lui.
class TvDirectionalFocusAction extends DirectionalFocusAction {
  TvDirectionalFocusAction();

  static DateTime? _lastMove;

  @override
  void invoke(DirectionalFocusIntent intent) {
    if (TvMode.isTv && TvKeyRepeat.isRepeating) {
      final now = DateTime.now();
      final last = _lastMove;
      if (last != null && now.difference(last) < TvKeyRepeat.repeatInterval) {
        return;
      }
      _lastMove = now;
    } else {
      _lastMove = DateTime.now();
    }
    super.invoke(intent);
  }
}
