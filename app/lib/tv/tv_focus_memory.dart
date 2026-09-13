import 'package:flutter/widgets.dart';

import 'tv_mode.dart';

/// Une zone qui se souvient de l'élément sur lequel la télécommande était.
///
/// C'est la logique des rangées de Jellyfin sur Android TV (et de Leanback en
/// général) : descendre vers une rangée puis remonter ramène sur l'affiche où
/// l'on était, et non sur celle qui se trouve géométriquement au-dessus. Sans
/// cela, parcourir l'accueil revient à perdre sa place dans chaque rangée à
/// chaque passage — on avance de dix affiches, on descend voir la rangée
/// suivante, on remonte, et l'on est revenu au début.
///
/// Même chose à l'échelle d'un onglet : quitter le contenu pour l'en-tête puis
/// y redescendre ramène à l'endroit exact d'où l'on est parti.
///
/// Le principe : chaque [TvFocusable] déclare à la mémoire la plus proche qu'il
/// vient de prendre le focus. Quand le focus *entre* dans la zone depuis
/// l'extérieur, la zone le redirige vers l'élément mémorisé s'il existe encore.
/// La première visite, rien n'est mémorisé, et le parcours directionnel de
/// Flutter garde la main.
///
/// Les mémoires s'emboîtent : une rangée dans un onglet signale aussi l'élément
/// à l'onglet. Hors téléviseur, la zone ne redirige jamais rien.
class TvFocusMemory extends StatefulWidget {
  const TvFocusMemory({super.key, required this.child});

  final Widget child;

  /// La mémoire la plus proche au-dessus de [context], s'il y en a une.
  ///
  /// Sans dépendance : un élément qui prend le focus n'a pas à se reconstruire
  /// quand la mémoire change.
  static TvFocusMemoryState? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<_TvFocusMemoryScope>()
        ?.state;
  }

  @override
  State<TvFocusMemory> createState() => TvFocusMemoryState();
}

class TvFocusMemoryState extends State<TvFocusMemory> {
  final FocusNode _node = FocusNode(
    debugLabel: 'tv-focus-memory',
    canRequestFocus: false,
    skipTraversal: true,
  );

  FocusNode? _remembered;
  TvFocusMemoryState? _parent;

  /// L'élément que la zone rendra au prochain retour. Exposé pour les tests.
  @visibleForTesting
  FocusNode? get remembered => _remembered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = TvFocusMemory.maybeOf(context);
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  /// Appelé par un élément qui vient de recevoir le focus.
  void remember(FocusNode node) {
    _remembered = node;
    _parent?.remember(node);
  }

  /// Appelé par un élément qui quitte l'arbre : son nœud va être détruit, et
  /// demander le focus sur un nœud détruit est une erreur.
  void forget(FocusNode node) {
    if (identical(_remembered, node)) _remembered = null;
    _parent?.forget(node);
  }

  void _handleFocusChange(bool hasFocus) {
    if (!hasFocus || !TvMode.isTv) return;
    final target = _remembered;
    if (target == null) return;
    if (identical(FocusManager.instance.primaryFocus, target)) return;
    // Encore dans l'arbre, encore dans cette zone, encore atteignable. Une
    // rangée rechargée a pu reconstruire ses cartes : on laisse alors le
    // parcours directionnel choisir, plutôt que de viser un fantôme.
    if (target.context == null ||
        !target.canRequestFocus ||
        !target.ancestors.contains(_node)) {
      _remembered = null;
      return;
    }
    target.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _handleFocusChange,
      child: _TvFocusMemoryScope(state: this, child: widget.child),
    );
  }
}

class _TvFocusMemoryScope extends InheritedWidget {
  const _TvFocusMemoryScope({required this.state, required super.child});

  final TvFocusMemoryState state;

  @override
  bool updateShouldNotify(_TvFocusMemoryScope oldWidget) =>
      !identical(oldWidget.state, state);
}
