/// Ce que les touches de la télécommande LG devraient dire au navigateur.
///
/// Le moteur web de webOS livre les touches propres au téléviseur avec leur
/// seul `keyCode` (461 pour Retour, 415 pour Lecture…) : leur `key` vaut
/// « Unidentified », ou un nom de clavier de bureau — 19 sort en « Pause »,
/// la touche d'interruption d'un PC. Flutter ne lit que `key` et `code` :
/// sans réécriture, Retour ne fermerait rien et Lecture et Pause
/// n'arriveraient pas au lecteur. Cette table donne à chaque touche le nom que Flutter attend ;
/// `webos_remote.dart` réécrit l'événement avant qu'il ne l'atteigne.
library;

/// Le nom W3C (`key` et `code`, identiques pour ces touches) de chaque touche
/// réécrite, par `keyCode`. Les flèches et OK (13) n'y sont pas : le
/// navigateur les nomme déjà comme un clavier.
const webOSRemoteKeys = <int, String>{
  // Retour. Échap plutôt que « GoBack » : c'est la touche que tout l'habillage
  // TV traite déjà comme un retour (`tv_focus.dart`), lecteur compris.
  461: 'Escape',
  415: 'MediaPlay',
  19: 'MediaPause',
  413: 'MediaStop',
  417: 'MediaFastForward',
  412: 'MediaRewind',
};

/// Le nom à donner à l'événement, ou null s'il est déjà juste ou n'est pas une
/// touche de télécommande.
String? webOSRemoteKeyName({required int keyCode, required String key}) {
  final mapped = webOSRemoteKeys[keyCode];
  if (mapped == null || mapped == key) return null;
  return mapped;
}
