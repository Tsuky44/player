import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';

/// Sait si la fenêtre de l'app a le focus du système.
///
/// Le lecteur reprend le focus clavier dès qu'il lui échappe. Quand c'est la
/// fenêtre entière qui le perd — l'utilisateur est passé sur une autre app —
/// le reprendre revient à demander au système le focus d'une fenêtre inactive.
/// Mesuré sous Windows : le clic suivant sur l'image ramène bien la fenêtre
/// devant, mais n'arrive jamais à Flutter, et il fallait cliquer une seconde
/// fois pour mettre en pause.
///
/// Là où le système n'annonce pas ce changement, [focused] reste vrai et rien
/// ne change.
class WindowFocusWatch with WidgetsBindingObserver {
  WindowFocusWatch({required this.onRegained});

  /// La fenêtre vient de retrouver le focus : à l'appelant de reprendre le
  /// sien s'il ne lui a pas été rendu.
  final VoidCallback onRegained;

  bool _focused = true;
  bool get focused => _focused;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void dispose() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    final focused = event.state == ViewFocusState.focused;
    if (focused == _focused) return;
    _focused = focused;
    if (focused) onRegained();
  }
}
