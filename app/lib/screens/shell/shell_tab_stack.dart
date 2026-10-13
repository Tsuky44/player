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
class ShellTabStack extends StatefulWidget {
  const ShellTabStack({
    super.key,
    required this.selected,
    required this.mounted,
    required this.tabs,
  });

  /// L'identifiant de l'onglet affiché ; le premier si aucun ne le porte.
  final String selected;

  /// Les onglets déjà construits. Les autres restent vides jusqu'à ce qu'on
  /// les ouvre, ou que l'accueil ait fini de se poser.
  final Set<String> mounted;

  /// Les onglets par identifiant, dans leur ordre. Chacun garde son état sous
  /// son identifiant : une bibliothèque ajoutée ou retirée ne déplace pas
  /// celui des autres (voir [ShellTabs]).
  final Map<String, Widget> tabs;

  @override
  State<ShellTabStack> createState() => _ShellTabStackState();
}

class _ShellTabStackState extends State<ShellTabStack> {
  /// Une clé globale par onglet. [IndexedStack] enveloppe chacun de ses
  /// enfants et les apparie par rang : une clé locale n'y survit pas, et une
  /// bibliothèque insérée au milieu ferait renaître tous les onglets suivants.
  final Map<String, GlobalKey> _keys = {};

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    final mounted = widget.mounted;
    final ids = tabs.keys.toList();
    _keys.removeWhere((id, _) => !tabs.containsKey(id));
    final found = ids.indexOf(widget.selected);
    final index = found < 0 ? 0 : found;
    return IndexedStack(
      index: index,
      children: [
        for (final (position, id) in ids.indexed)
          KeyedSubtree(
            key: _keys.putIfAbsent(id, () => GlobalKey(debugLabel: id)),
            child: TickerMode(
              enabled: position == index,
              child: ExcludeFocus(
                excluding: position != index,
                // Redescendre de l'en-tête ramène là où l'on était dans cet
                // onglet — voir [TvFocusMemory].
                child: mounted.contains(id)
                    ? TvFocusMemory(child: tabs[id]!)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
  }
}
