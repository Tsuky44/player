/// Dit si un lecteur est ouvert, où qu'il ait été lancé.
///
/// [PlayerScreen] s'ouvre depuis six endroits (accueil, fiches, téléchargements,
/// watch party, reprise à distance…) : c'est lui qui s'annonce, plutôt que
/// chacun de ses appelants. Un compteur et pas un booléen, parce qu'un
/// lecteur peut en remplacer un autre (épisode suivant) et que le nouveau
/// arrive avant que l'ancien ne soit démonté.
abstract final class PlayerPresence {
  static int _open = 0;

  static bool isOpen() => _open > 0;

  static void enter() => _open++;

  static void leave() {
    if (_open > 0) _open--;
  }
}
