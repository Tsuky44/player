import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Un écran découpé en rangées que la télécommande parcourt en lignes droites.
///
/// Le parcours directionnel de Flutter devine sa cible d'après la géométrie :
/// il marche bien sur une grille régulière, mal sur un écran de lecteur où les
/// réglages sont en haut à droite, la lecture au centre et la barre de
/// progression en bas. Haut depuis le bouton lecture pouvait alors tomber sur
/// le bouton retour, gauche depuis « reculer » sortir de la rangée vers la
/// barre, et l'on ne savait plus où l'on était.
///
/// Ici l'ordre est explicite, comme sur Crunchyroll ou Jellyfin :
/// - gauche et droite restent dans la rangée, et s'arrêtent à ses bords ;
/// - haut et bas passent à la rangée voisine, sur son élément préféré
///   ([TvFocusRow.preferredFocus]) ou, à défaut, sur celui qui est le plus
///   proche horizontalement de l'élément quitté.
///
/// Les rangées sont ordonnées par leur position à l'écran, pas par leur ordre
/// dans l'arbre. Une rangée sans rien de focalisable (masquée, vide) est sautée.
class TvFocusRows extends StatefulWidget {
  const TvFocusRows({super.key, required this.child, this.onNavigate});

  final Widget child;

  /// Appelé à chaque déplacement du focus fait par ces rangées — pour relancer
  /// le compte à rebours qui masque les contrôles, par exemple.
  final VoidCallback? onNavigate;

  @override
  State<TvFocusRows> createState() => _TvFocusRowsState();
}

class _TvFocusRowsState extends State<TvFocusRows> {
  final List<_TvFocusRowState> _rows = <_TvFocusRowState>[];

  void _register(_TvFocusRowState row) {
    if (!_rows.contains(row)) _rows.add(row);
  }

  void _unregister(_TvFocusRowState row) => _rows.remove(row);

  void _notifyNavigate() => widget.onNavigate?.call();

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final int step;
    if (key == LogicalKeyboardKey.arrowUp) {
      step = -1;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      step = 1;
    } else {
      return KeyEventResult.ignored;
    }

    final current = FocusManager.instance.primaryFocus;
    if (current == null || current.context == null) {
      return KeyEventResult.ignored;
    }

    final rows = _rows.where((row) => row._focusables.isNotEmpty).toList()
      ..sort((a, b) => a._node.rect.center.dy.compareTo(b._node.rect.center.dy));
    final index = rows.indexWhere((row) => row._node.hasFocus);
    if (index < 0) return KeyEventResult.ignored;

    final targetIndex = index + step;
    // Au bord de l'écran : on s'arrête là, plutôt que de laisser le parcours
    // par défaut emmener le focus hors des contrôles.
    if (targetIndex < 0 || targetIndex >= rows.length) {
      return KeyEventResult.handled;
    }

    final target = rows[targetIndex]._entryFor(current.rect.center.dx);
    if (target == null) return KeyEventResult.handled;
    target.requestFocus();
    _notifyNavigate();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: _TvFocusRowsScope(state: this, child: widget.child),
    );
  }
}

class _TvFocusRowsScope extends InheritedWidget {
  const _TvFocusRowsScope({required this.state, required super.child});

  final _TvFocusRowsState state;

  @override
  bool updateShouldNotify(_TvFocusRowsScope oldWidget) =>
      !identical(oldWidget.state, state);
}

/// Une rangée de [TvFocusRows].
class TvFocusRow extends StatefulWidget {
  const TvFocusRow({super.key, required this.child, this.preferredFocus});

  final Widget child;

  /// Où arrive la télécommande quand elle entre dans cette rangée par le haut
  /// ou par le bas — la lecture au centre, la barre en bas.
  final FocusNode? preferredFocus;

  @override
  State<TvFocusRow> createState() => _TvFocusRowState();
}

class _TvFocusRowState extends State<TvFocusRow> {
  final FocusNode _node = FocusNode(
    debugLabel: 'tv-focus-row',
    canRequestFocus: false,
    skipTraversal: true,
  );

  _TvFocusRowsState? _rows;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rows = context
        .getInheritedWidgetOfExactType<_TvFocusRowsScope>()
        ?.state;
    if (identical(rows, _rows)) return;
    _rows?._unregister(this);
    _rows = rows;
    _rows?._register(this);
  }

  @override
  void dispose() {
    _rows?._unregister(this);
    _node.dispose();
    super.dispose();
  }

  /// Ce que la télécommande peut atteindre dans la rangée, de gauche à droite.
  /// Vide quand la rangée est masquée : un [ExcludeFocus] au-dessus rend ses
  /// éléments non focalisables.
  List<FocusNode> get _focusables {
    if (!mounted || _node.context == null) return const <FocusNode>[];
    return _node.traversalDescendants
        .where((node) => node.context != null && node.canRequestFocus)
        .toList()
      ..sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
  }

  FocusNode? _entryFor(double fromX) {
    final preferred = widget.preferredFocus;
    final focusables = _focusables;
    if (preferred != null && focusables.contains(preferred)) return preferred;
    if (focusables.isEmpty) return null;
    return focusables.reduce((best, node) =>
        (node.rect.center.dx - fromX).abs() < (best.rect.center.dx - fromX).abs()
            ? node
            : best);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final int step;
    if (key == LogicalKeyboardKey.arrowLeft) {
      step = -1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      step = 1;
    } else {
      return KeyEventResult.ignored;
    }

    final focusables = _focusables;
    final current = FocusManager.instance.primaryFocus;
    final index = current == null ? -1 : focusables.indexOf(current);
    if (index < 0) return KeyEventResult.ignored;

    final target = index + step;
    // Le bord de la rangée est un mur, pas une porte vers la rangée d'à côté.
    if (target < 0 || target >= focusables.length) {
      return KeyEventResult.handled;
    }
    focusables[target].requestFocus();
    _rows?._notifyNavigate();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: widget.child,
    );
  }
}
