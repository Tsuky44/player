import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../utils/app_platform.dart';
import '../../utils/poster_grid_zoom.dart';

/// Ctrl + molette (⌘ + molette sur Mac, pincement du pavé tactile) sur une
/// page en grille d'affiches : la molette vers le haut agrandit les affiches
/// (moins de colonnes), vers le bas en met davantage par ligne.
///
/// Entoure la page entière. Les grilles lisent le zoom par
/// `AppLayout.posterGridDelegate`, qui s'abonne à [PosterGridZoomScope] depuis
/// son `SliverLayoutBuilder`.
class PosterGridZoomRegion extends StatefulWidget {
  final Widget child;

  const PosterGridZoomRegion({super.key, required this.child});

  /// Seuls un ordinateur et un navigateur ont une molette : sur un téléphone ou
  /// un téléviseur, la région ne fait que transmettre sa page.
  static bool get supported => AppPlatform.isDesktop || AppPlatform.isWeb;

  @override
  State<PosterGridZoomRegion> createState() => _PosterGridZoomRegionState();
}

class _PosterGridZoomRegionState extends State<PosterGridZoomRegion> {
  /// Défilement cumulé qui vaut un cran de zoom. Une molette de souris envoie
  /// ~100 par cran, un pavé tactile une rafale de petits pas : le seuil évite
  /// qu'un pincement fasse sauter dix colonnes d'un coup.
  static const double _scrollPerStep = 40;

  final PosterGridZoom _zoom = PosterGridZoom();
  double _pendingScroll = 0;
  bool _modifierHeld = false;

  @override
  void initState() {
    super.initState();
    // Le curseur de zoom règle aussi les téléphones et les tablettes : l'écart
    // enregistré se lit partout, la molette n'est écoutée que là où il y en a.
    PosterGridZoom.load();
    if (!PosterGridZoomRegion.supported) return;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    if (PosterGridZoomRegion.supported) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    _zoom.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final held = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (held != _modifierHeld) {
      _pendingScroll = 0;
      setState(() => _modifierHeld = held);
    }
    // Ne consomme rien : les raccourcis de l'app continuent de recevoir la touche.
    return false;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_modifierHeld) return;
    _pendingScroll += event.scrollDelta.dy;
    if (_pendingScroll.abs() < _scrollPerStep) return;
    // Molette vers le bas (dy > 0) : on recule, donc plus d'affiches par ligne.
    _zoom.step(_pendingScroll > 0 ? 1 : -1);
    _pendingScroll = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (!PosterGridZoomRegion.supported) {
      return PosterGridZoomScope(zoom: _zoom, child: widget.child);
    }
    // Le défilement ne doit pas bouger pendant qu'on zoome : Flutter ne
    // distingue pas Ctrl + molette de la molette seule. Tant qu'on tient Ctrl,
    // la page ignore le pointeur et seul ce Listener (translucent, donc touché
    // quand même) reçoit la molette. L'IgnorePointer est toujours là, seul son
    // réglage change, pour que l'arbre de la page (position de défilement,
    // champ de recherche) ne soit pas recréé quand on appuie sur Ctrl.
    return PosterGridZoomScope(
      zoom: _zoom,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _onPointerSignal,
        child: IgnorePointer(
          ignoring: _modifierHeld,
          child: widget.child,
        ),
      ),
    );
  }
}
