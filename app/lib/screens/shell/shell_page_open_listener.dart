import 'package:flutter/widgets.dart';

/// Dit à `MainShell` si une page (fiche d'un média, d'une personne…) est
/// ouverte par-dessus les onglets, dans le navigateur de [navigatorKey].
///
/// La réponse est lue sur le navigateur au moment où la notification arrive,
/// jamais dans la notification. Chaque reconstruction de la coquille donne au
/// navigateur une nouvelle page d'onglets. Il vide alors son historique puis
/// le remplit, et chaque étape met en file sa propre [NavigationNotification]
/// : `false`, `false`, puis `true` quand une fiche est ouverte. Lues telles
/// quelles, elles faisaient croire à la coquille que la fiche s'était fermée
/// puis rouverte. La coquille se reconstruisait, ce qui remettait les pages à
/// jour, et ainsi de suite à chaque frame tant qu'une fiche restait ouverte, y
/// compris sous le lecteur. Mesuré sous Windows : ~55 ms de thread UI par
/// frame, les cinq onglets reconstruits à chaque fois. Sous Windows la vidéo
/// est une texture Flutter, et ce temps était pris sur ses images.
///
/// Quand les notifications partent (après la frame), l'historique est
/// complet : le `canPop` du navigateur est la seule source fiable.
class ShellPageOpenListener extends StatelessWidget {
  const ShellPageOpenListener({
    super.key,
    required this.navigatorKey,
    required this.pageOpen,
    required this.onPageOpenChanged,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;

  /// Ce que la coquille croit en ce moment. Seul un changement est signalé.
  final bool pageOpen;

  final ValueChanged<bool> onPageOpenChanged;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<NavigationNotification>(
      onNotification: (_) {
        final open = navigatorKey.currentState?.canPop() ?? false;
        if (open != pageOpen) onPageOpenChanged(open);
        return false;
      },
      child: child,
    );
  }
}
