/// Ce qui retient le chrome du lecteur à l'écran quand son compte à rebours
/// de quatre secondes arrive au bout.
///
/// Une seule règle, pour que les raisons de rester s'ajoutent ici plutôt que
/// dans le rappel du minuteur.
bool chromeMayAutoHide({
  required bool isPlaying,
  required bool isDraggingSlider,
  required bool menuOpen,
}) {
  // Un film en pause garde son chrome : il n'y a rien à regarder derrière.
  if (!isPlaying) return false;
  if (isDraggingSlider) return false;
  // Un menu ouvert est posé sur le chrome, qui lui sert de contexte. Le
  // pointeur survole le menu (une entrée d'overlay, hors de la zone qui
  // réarme le minuteur) : le chrome s'effaçait donc sous un menu en cours
  // d'utilisation. La fermeture du menu relance le compte à rebours.
  if (menuOpen) return false;
  return true;
}
