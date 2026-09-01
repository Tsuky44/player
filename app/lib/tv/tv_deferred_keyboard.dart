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
/// atteindre dans l'en-tête, la barre de recherche étant juste avant lui.
///
/// Le champ se comporte donc comme un bouton : il est **hors du parcours**
/// jusqu'à ce qu'on appuie sur OK dessus, et il redevient un bouton dès que le
/// clavier se referme. Hors téléviseur, rien de tout cela ne s'applique et le
/// champ se comporte exactement comme avant.
///
/// [builder] reçoit ce qu'il doit passer à son `TextField` : `canRequestFocus`.
/// Le champ garde son propre [fieldFocusNode], que ce widget demande au bon
/// moment.
class TvDeferredKeyboard extends StatefulWidget {
  const TvDeferredKeyboard({
    super.key,
    required this.fieldFocusNode,
    required this.builder,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  /// Le nœud du champ enveloppé. Ce widget l'observe pour savoir quand le
  /// clavier s'est refermé, et le réclame quand l'utilisateur active le champ.
  final FocusNode fieldFocusNode;

  final Widget Function(BuildContext context, bool canRequestFocus) builder;

  /// Épouse la forme du champ, pour que l'anneau de focus le suive.
  final BorderRadius borderRadius;

  @override
  State<TvDeferredKeyboard> createState() => _TvDeferredKeyboardState();
}

class _TvDeferredKeyboardState extends State<TvDeferredKeyboard> {
  /// Où se pose la télécommande tant que le champ est un bouton.
  final FocusNode _remoteNode = FocusNode(debugLabel: 'tv-deferred-keyboard');

  bool _keyboardRequested = false;

  @override
  void initState() {
    super.initState();
    widget.fieldFocusNode.addListener(_onFieldFocusChanged);
  }

  @override
  void didUpdateWidget(TvDeferredKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fieldFocusNode != widget.fieldFocusNode) {
      oldWidget.fieldFocusNode.removeListener(_onFieldFocusChanged);
      widget.fieldFocusNode.addListener(_onFieldFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.fieldFocusNode.removeListener(_onFieldFocusChanged);
    _remoteNode.dispose();
    super.dispose();
  }

  void _onFieldFocusChanged() {
    if (!_keyboardRequested || widget.fieldFocusNode.hasFocus) return;
    if (!mounted) return;
    // Le clavier s'est refermé. Le champ ressort du parcours, sinon le passage
    // suivant de la télécommande le rouvrirait tout seul — et le focus revient
    // sur le champ-bouton, pour ne laisser la télécommande nulle part.
    setState(() => _keyboardRequested = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _remoteNode.requestFocus();
    });
  }

  void _activate() {
    setState(() => _keyboardRequested = true);
    // Après la frame : le champ n'est focusable qu'une fois reconstruit avec
    // `canRequestFocus` à vrai.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.fieldFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.of(context)) return widget.builder(context, true);

    return TvFocusable(
      focusNode: _remoteNode,
      onSelect: _activate,
      borderRadius: widget.borderRadius,
      // Pas d'agrandissement : ces champs vivent dans des barres serrées, et
      // grandir les ferait chevaucher leurs voisins.
      focusScale: 1.0,
      child: widget.builder(context, _keyboardRequested),
    );
  }
}
