import 'dart:ui' show ViewFocusDirection, ViewFocusState;

import 'package:flutter/services.dart';
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
///
/// Un second cas : la vue elle-même perd le focus de la plateforme. Dans un
/// navigateur, c'est le cas dès que la page perd le focus — sur un téléviseur
/// LG, un clic du pointeur hors de l'app, un panneau du système, ou dans le
/// simulateur un clic sur la télécommande à l'écran. Flutter « gare » alors le
/// focus sur la racine, où aucune touche n'a d'effet, et rien ne l'en sort
/// sans un clic dans la page. Les touches, elles, arrivent toujours : la
/// première rend le focus à l'élément qui l'avait (voir [_handleKey]).
class TvFocusGuard extends StatefulWidget {
  const TvFocusGuard({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusGuard> createState() => _TvFocusGuardState();
}

class _TvFocusGuardState extends State<TvFocusGuard> {
  bool _restoring = false;

  /// Le dernier élément actionnable qui a tenu le focus : celui qu'on rend
  /// quand la vue récupère la main.
  FocusNode? _lastHeld;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    super.dispose();
  }

  void _onFocusChanged() {
    final focus = FocusManager.instance.primaryFocus;
    if (!focusIsStranded(focus)) _lastHeld = focus;
    if (!TvMode.isTv || _restoring || !mounted) return;
    // Garé par la vue : il n'y a rien à parcourir depuis la racine, qui n'est
    // dans aucun arbre de widgets — `nextFocus` y levait une exception à
    // chaque frame. La première touche s'en charge.
    if (!focusIsStranded(focus) || focusIsParked(focus)) return;

    // Après la frame : ce qui vient de détruire le nœud focalisé est
    // probablement en train de reconstruire l'arbre, et chercher une cible
    // maintenant la trouverait à moitié posée.
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoring = false;
      if (!mounted || !TvMode.isTv) return;
      final focus = FocusManager.instance.primaryFocus;
      if (!focusIsStranded(focus) || focusIsParked(focus)) return;
      // `nextFocus` depuis le conteneur courant : il descend dans le premier
      // élément atteignable de ce qui est à l'écran, sans que ce garde-fou
      // n'ait à savoir de quel écran il s'agit.
      focus?.nextFocus();
    });
  }

  /// Une touche reçue pendant que le focus est garé : la vue reprend le focus,
  /// et l'élément qui l'avait le retrouve. La touche elle-même est consommée —
  /// le focus réapparaît là où on l'avait laissé, la suivante le déplace.
  KeyEventResult _handleKey(KeyEvent event) {
    if (!TvMode.isTv || !mounted) return KeyEventResult.ignored;
    if (!focusIsParked(FocusManager.instance.primaryFocus)) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    // La vue d'abord. Quand la plateforme rend le focus à la page, Flutter
    // le pose sur le premier élément de l'écran ; demandé après, l'élément
    // retenu l'emporte.
    final view = View.maybeOf(context);
    if (view != null) {
      WidgetsBinding.instance.platformDispatcher.requestViewFocusChange(
        viewId: view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      );
    }
    final last = _lastHeld;
    if (last != null &&
        (last.context?.mounted ?? false) &&
        last.canRequestFocus) {
      last.requestFocus();
    } else {
      // Plus d'élément à qui le rendre : le conteneur de la vue, d'où
      // [_onFocusChanged] descend au premier élément atteignable.
      FocusScope.of(context).requestFocus();
    }
    return KeyEventResult.handled;
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

/// Vrai quand le focus est garé à la racine, hors de tout arbre de widgets.
///
/// C'est là que Flutter le met quand la vue perd le focus de la plateforme :
/// aucune touche n'y a d'effet, et rien ne peut en partir par parcours.
@visibleForTesting
bool focusIsParked(FocusNode? focus) =>
    focus is FocusScopeNode && focus.context == null;
