import 'package:flutter/widgets.dart';

/// Des volets posés côte à côte, entre lesquels gauche et droite passent
/// toujours — une liste de catégories et la page qu'elle ouvre.
///
/// Sur un téléviseur, gauche et droite ne quittent jamais la ligne (voir
/// `TvDirectionalFocusAction`) : c'est ce qui empêche le focus de sauter à
/// l'autre bout de l'écran au bout d'une rangée d'affiches. Entre deux volets
/// la règle devient un mur. Depuis « Lecture » dans la barre des paramètres,
/// droite ne menait à la page que si un réglage se trouvait par hasard à la
/// même hauteur ; devant un titre, un texte ou un groupe plus bas, le focus
/// restait dans la liste et la page était inatteignable.
///
/// Ici le passage est explicite : quand rien ne suit sur la ligne *dans le
/// volet courant*, la flèche entre dans le volet voisin — sur l'élément qu'on y
/// avait quitté, sinon sur celui de la même ligne, sinon sur le plus proche en
/// hauteur. Un volet sans rien de focalisable est sauté.
///
/// Les volets sont ordonnés par leur position à l'écran, pas par leur ordre
/// dans l'arbre.
class TvFocusPanes extends StatefulWidget {
  const TvFocusPanes({super.key, required this.child});

  final Widget child;

  /// Les volets qui contiennent [node], s'il y en a.
  static TvFocusPanesState? maybeOf(FocusNode node) => node.context
      ?.getInheritedWidgetOfExactType<_TvFocusPanesScope>()
      ?.state;

  @override
  State<TvFocusPanes> createState() => TvFocusPanesState();
}

class TvFocusPanesState extends State<TvFocusPanes> {
  final List<_TvFocusPaneState> _panes = <_TvFocusPaneState>[];

  void _register(_TvFocusPaneState pane) {
    if (!_panes.contains(pane)) _panes.add(pane);
  }

  void _unregister(_TvFocusPaneState pane) => _panes.remove(pane);

  /// Où va le focus depuis [from] vers la gauche ou la droite.
  ///
  /// [onLine] est ce que la règle « même ligne » a trouvé sur tout l'écran : on
  /// le garde tel quel s'il est dans le volet de [from], et il sert de point
  /// d'entrée s'il est dans le volet voisin. Nul quand il n'y a nulle part où
  /// aller.
  FocusNode? next(
    FocusNode from,
    TraversalDirection direction, {
    FocusNode? onLine,
  }) {
    final panes = _panes.where((pane) => pane.mounted).toList()
      ..sort((a, b) => a._node.rect.left.compareTo(b._node.rect.left));
    final index = panes.indexWhere((pane) => pane._contains(from));
    // Hors de tout volet (un en-tête au-dessus d'eux) : la règle générale.
    if (index < 0) return onLine;
    final here = panes[index];
    if (onLine != null && here._contains(onLine)) return onLine;

    final step = direction == TraversalDirection.right ? 1 : -1;
    for (var i = index + step; i >= 0 && i < panes.length; i += step) {
      final entry = panes[i]._entryFrom(from, onLine);
      if (entry == null) continue;
      here._last = from;
      return entry;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) =>
      _TvFocusPanesScope(state: this, child: widget.child);
}

class _TvFocusPanesScope extends InheritedWidget {
  const _TvFocusPanesScope({required this.state, required super.child});

  final TvFocusPanesState state;

  @override
  bool updateShouldNotify(_TvFocusPanesScope oldWidget) =>
      !identical(oldWidget.state, state);
}

/// Un volet de [TvFocusPanes].
class TvFocusPane extends StatefulWidget {
  const TvFocusPane({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusPane> createState() => _TvFocusPaneState();
}

class _TvFocusPaneState extends State<TvFocusPane> {
  final FocusNode _node = FocusNode(
    debugLabel: 'tv-focus-pane',
    canRequestFocus: false,
    skipTraversal: true,
  );

  TvFocusPanesState? _panes;

  /// L'élément d'où l'on est sorti du volet : y revenir ramène au même
  /// endroit, la catégorie ouverte comme le réglage qu'on regardait.
  FocusNode? _last;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final panes =
        context.getInheritedWidgetOfExactType<_TvFocusPanesScope>()?.state;
    if (identical(panes, _panes)) return;
    _panes?._unregister(this);
    _panes = panes;
    _panes?._register(this);
  }

  @override
  void dispose() {
    _panes?._unregister(this);
    _node.dispose();
    super.dispose();
  }

  bool _contains(FocusNode node) => node.ancestors.contains(_node);

  FocusNode? _entryFrom(FocusNode from, FocusNode? onLine) {
    final focusables = _node.traversalDescendants
        .where((node) => node.context != null && !node.rect.isEmpty)
        .toList();
    if (focusables.isEmpty) return null;

    final last = _last;
    if (last != null && focusables.contains(last)) return last;
    // La page a changé depuis : l'élément mémorisé n'existe plus.
    _last = null;
    if (onLine != null && focusables.contains(onLine)) return onLine;

    final origin = from.rect;
    double gap(FocusNode node) {
      final rect = node.rect;
      if (rect.top > origin.bottom) return rect.top - origin.bottom;
      if (rect.bottom < origin.top) return origin.top - rect.bottom;
      return 0;
    }

    // Le plus proche en hauteur ; à égalité, le plus proche du volet quitté.
    return focusables.reduce((best, node) {
      final byHeight = gap(node).compareTo(gap(best));
      if (byHeight != 0) return byHeight < 0 ? node : best;
      final nodeDx = (node.rect.center.dx - origin.center.dx).abs();
      final bestDx = (best.rect.center.dx - origin.center.dx).abs();
      return nodeDx < bestDx ? node : best;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
