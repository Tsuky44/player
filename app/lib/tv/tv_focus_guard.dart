import 'package:flutter/widgets.dart';

import 'tv_mode.dart';

/// Redonne le focus quand il n'y a plus personne pour le tenir.
///
/// Sur un téléviseur, tout passe par le focus : s'il n'est nulle part, la
/// télécommande ne fait plus rien du tout, et l'écran a l'air gelé alors qu'il
/// va très bien. Flutter n'a pas de filet pour ça — quand le widget focalisé
/// disparaît, le focus remonte au conteneur le plus proche et s'y arrête.
///
/// Or les listes de cette app se rafraîchissent sous les pieds de
/// l'utilisateur : revenir d'un film recharge l'accueil, ce qui reconstruit
/// « Reprendre la lecture » — et détruit la vignette qui avait le focus. Le
/// symptôme est immédiat et déroutant : plus rien ne répond.
///
/// Ce garde-fou remet donc le focus sur le premier élément atteignable dès
/// qu'il constate qu'aucun ne l'a. Rien de tout cela ne s'applique hors
/// téléviseur, où le pointeur n'a pas besoin qu'on lui tienne la main.
class TvFocusGuard extends StatefulWidget {
  const TvFocusGuard({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusGuard> createState() => _TvFocusGuardState();
}

class _TvFocusGuardState extends State<TvFocusGuard> {
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!TvMode.isTv || _restoring || !mounted) return;
    if (!focusIsStranded(FocusManager.instance.primaryFocus)) return;

    // Après la frame : ce qui vient de détruire le nœud focalisé est
    // probablement en train de reconstruire l'arbre, et chercher une cible
    // maintenant la trouverait à moitié posée.
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoring = false;
      if (!mounted || !TvMode.isTv) return;
      final focus = FocusManager.instance.primaryFocus;
      if (!focusIsStranded(focus)) return;
      // `nextFocus` depuis le conteneur courant : il descend dans le premier
      // élément atteignable de ce qui est à l'écran, sans que ce garde-fou
      // n'ait à savoir de quel écran il s'agit.
      focus?.nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Vrai quand personne d'actionnable ne détient le focus.
///
/// Un [FocusScopeNode] qui détient le focus principal veut dire « le focus est
/// entré ici mais ne s'est posé sur rien » : c'est l'état où la télécommande
/// est sans effet. Un nœud ordinaire, lui, est un élément que l'utilisateur
/// peut activer.
@visibleForTesting
bool focusIsStranded(FocusNode? focus) =>
    focus == null || focus is FocusScopeNode;
