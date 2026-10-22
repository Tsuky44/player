/*
  La télécommande LG, rendue lisible par Flutter (ADR-0076).

  Le moteur web de webOS livre les touches propres au téléviseur avec leur
  seul `keyCode` (461 pour Retour, 415 pour Lecture…) : leur `key` vaut
  « Unidentified », « GoBack », ou un nom de clavier de bureau — 19 sort en
  « Pause », la touche d'interruption d'un PC. Flutter ne lit que `key` et
  `code` : sans réécriture, Lecture et Pause n'arriveraient pas au lecteur.

  Chargé avant flutter_bootstrap.js, et c'est tout son intérêt : Flutter écoute
  les touches sur la fenêtre, en phase de capture, et les écouteurs d'une même
  cible passent dans l'ordre où ils ont été posés. Posée depuis Dart, la
  réécriture passait après Flutter, qui voyait les deux événements : un Retour
  nommé « GoBack » (c'est le nom que lui donne le simulateur de LG) aurait été
  lu « GoBack » puis « Escape », et aurait reculé de deux écrans.
*/
(function () {
  if (!/web0s|webos/i.test(navigator.userAgent)) return;

  // Le nom W3C (`key` et `code`, identiques pour ces touches) de chaque touche
  // réécrite, par `keyCode`. Les flèches et OK n'y sont pas : le moteur les
  // nomme déjà comme un clavier.
  var NAMES = {
    // Retour. Échap plutôt que « GoBack » : c'est la touche que tout
    // l'habillage TV traite déjà comme un retour (`tv_focus.dart`), lecteur
    // compris, et le relâchement de Retour arrive sans nom.
    461: 'Escape',
    415: 'MediaPlay',
    19: 'MediaPause',
    413: 'MediaStop',
    417: 'MediaFastForward',
    412: 'MediaRewind'
  };

  // L'événement que ce script émet lui-même repasse par cet écouteur. Le
  // filtre ne regarde pas `isTrusted` : le simulateur de LG émet ces touches
  // en événements synthétiques, qui seraient restés sans nom.
  var rewriting = false;

  function rewrite(event) {
    if (rewriting) return;
    var name = NAMES[event.keyCode];
    if (!name || name === event.key || !event.target) return;

    // preventDefault aussi : webOS ferait sinon son propre geste de la touche.
    event.preventDefault();
    event.stopImmediatePropagation();
    rewriting = true;
    try {
      event.target.dispatchEvent(new KeyboardEvent(event.type, {
        key: name,
        code: name,
        keyCode: event.keyCode,
        repeat: event.repeat,
        bubbles: true,
        cancelable: true,
        composed: true
      }));
    } finally {
      rewriting = false;
    }
  }

  window.addEventListener('keydown', rewrite, true);
  window.addEventListener('keyup', rewrite, true);
})();
