import 'package:flutter/material.dart';

import 'tv_focus.dart';
import 'tv_mode.dart';

/// Un champ de saisie qu'une télécommande ne réveille qu'à la demande.
///
/// Sur Android, un champ qui prend le focus fait ouvrir le clavier virtuel — et
/// sur un téléviseur ce clavier est plein écran. Un champ posé sur le chemin du
/// parcours du focus devient donc un mur : la croix directionnelle le traverse,
/// le clavier s'ouvre par-dessus tout, et ce qui se trouve après lui est
/// inatteignable. C'est ce qui rendait l'avatar du compte impossible à
/// atteindre dans l'en-tête, la barre de recherche étant juste avant lui — puis
/// chaque champ des Réglages, l'un après l'autre.
///
/// Le champ se comporte donc comme un bouton : il est **hors du parcours**
/// jusqu'à ce qu'on appuie sur OK dessus, et il en ressort dès que le clavier se
/// referme. Hors téléviseur, ce widget est transparent : le champ prend le focus
/// au clic, exactement comme avant.
///
/// ```dart
/// TvDeferredKeyboard(
///   builder: (context, focusNode, canRequestFocus) => TextField(
///     focusNode: focusNode,
///     canRequestFocus: canRequestFocus,
///     decoration: const InputDecoration(labelText: 'Adresse'),
///   ),
/// )
/// ```
///
/// Le nœud est fourni par le widget, parce que sans cela chaque champ de l'app
/// aurait dû s'en créer un — quinze déclarations et quinze `dispose` dont
/// l'oubli ne se voit pas. Les rares champs qui en possèdent déjà un (la barre
/// de recherche, le formulaire de connexion qui enchaîne ses champs) le passent
/// par [fieldFocusNode].
class TvDeferredKeyboard extends StatefulWidget {
  const TvDeferredKeyboard({
    super.key,
    required this.builder,
    this.fieldFocusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  /// Construit le champ. Reçoit le nœud à lui donner, et ce qu'il doit passer à
  /// son `canRequestFocus`.
  final Widget Function(
    BuildContext context,
    FocusNode focusNode,
    bool canRequestFocus,
  ) builder;

  /// Pour un appelant qui possède déjà le nœud — parce qu'il l'observe, ou
  /// parce qu'il enchaîne le focus d'un champ au suivant. Sinon ce widget en
  /// crée un et s'en occupe.
  final FocusNode? fieldFocusNode;

  /// Épouse la forme du champ, pour que l'anneau de focus le suive.
  final BorderRadius borderRadius;

  @override
  State<TvDeferredKeyboard> createState() => TvDeferredKeyboardState();
}

class TvDeferredKeyboardState extends State<TvDeferredKeyboard> {
  /// Où se pose la télécommande tant que le champ est un bouton.
  final FocusNode _remoteNode = FocusNode(debugLabel: 'tv-deferred-keyboard');

  /// Créé ici quand l'appelant n'en fournit pas — et détruit ici seulement
  /// dans ce cas : celui de l'appelant ne nous appartient pas.
  FocusNode? _ownedNode;

  bool _keyboardRequested = false;

  FocusNode get _fieldNode =>
      widget.fieldFocusNode ?? (_ownedNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _fieldNode.addListener(_onFieldFocusChanged);
  }

  @override
  void didUpdateWidget(TvDeferredKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fieldFocusNode != widget.fieldFocusNode) {
      oldWidget.fieldFocusNode?.removeListener(_onFieldFocusChanged);
      _fieldNode.addListener(_onFieldFocusChanged);
    }
  }

  @override
  void dispose() {
    _fieldNode.removeListener(_onFieldFocusChanged);
    _ownedNode?.dispose();
    _remoteNode.dispose();
    super.dispose();
  }

  void _onFieldFocusChanged() {
    if (!_keyboardRequested || _fieldNode.hasFocus || !mounted) return;
    // Le clavier s'est refermé. Le champ ressort du parcours, sinon le passage
    // suivant de la télécommande le rouvrirait tout seul — et le focus revient
    // sur le champ-bouton, pour ne laisser la télécommande nulle part.
    setState(() => _keyboardRequested = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _remoteNode.requestFocus();
    });
  }

  /// Ouvre le clavier sur ce champ.
  ///
  /// Appelé par OK sur le champ-bouton, et exposé pour les formulaires qui
  /// enchaînent leurs champs : sans cela, passer au champ suivant lui donnerait
  /// le focus sans que le clavier ne s'ouvre.
  ///
  /// Surtout pas nommée `activate` : [State] en a déjà une, que Flutter appelle
  /// quand l'état est réinséré dans l'arbre — le clavier se serait ouvert de
  /// lui-même à chaque fois.
  void requestKeyboard() {
    if (!mounted) return;
    setState(() => _keyboardRequested = true);
    // Après la frame : le champ n'est focusable qu'une fois reconstruit avec
    // `canRequestFocus` à vrai.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.of(context)) {
      return widget.builder(context, _fieldNode, true);
    }

    return TvFocusable(
      focusNode: _remoteNode,
      onSelect: requestKeyboard,
      borderRadius: widget.borderRadius,
      // Pas d'agrandissement : ces champs vivent dans des formulaires serrés,
      // et grandir les ferait chevaucher leurs voisins.
      focusScale: 1.0,
      child: widget.builder(context, _fieldNode, _keyboardRequested),
    );
  }
}
