import 'package:flutter/widgets.dart';

import '../../tv/tv_focus_memory.dart';

/// Les onglets principaux, tous gardés vivants, un seul à l'écran.
///
/// Un [IndexedStack] garde chaque onglet dans l'arbre et n'en peint qu'un :
/// c'est ce qui rend le changement d'onglet instantané. Mais il ne coupe pas
/// leurs animations. Un indicateur de chargement resté dans un onglet caché
/// (« Demandes » qui charge sa page suivante, un bandeau qui défile) demande
/// alors une image à chaque rafraîchissement de l'écran, pour toujours — 120
/// par seconde sur un écran ProMotion — alors que rien de visible ne bouge.
/// L'app au repos faisait ainsi chauffer un Mac. [TickerMode] les suspend
/// tant que l'onglet est caché, et les reprend quand on y revient.
///
/// La même raison vaut pour le focus : le parcours au D-pad lit l'arbre, pas
/// l'écran, et entrerait dans des affiches que personne ne voit.
class ShellTabStack extends StatelessWidget {
  const ShellTabStack({
    super.key,
    required this.selectedIndex,
    required this.mounted,
    required this.tabs,
  });

  /// L'onglet affiché.
  final int selectedIndex;

  /// Les onglets déjà construits. Les autres restent vides jusqu'à ce qu'on
  /// les ouvre, ou que l'accueil ait fini de se poser.
  final Set<int> mounted;

  final List<Widget> tabs;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: selectedIndex,
      children: [
        for (final (index, tab) in tabs.indexed)
          TickerMode(
            enabled: index == selectedIndex,
            child: ExcludeFocus(
              excluding: index != selectedIndex,
              // Redescendre de l'en-tête ramène là où l'on était dans cet
              // onglet — voir [TvFocusMemory].
              child: mounted.contains(index)
                  ? TvFocusMemory(child: tab)
                  : const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}
