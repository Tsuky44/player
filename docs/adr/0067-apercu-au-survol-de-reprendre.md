# ADR-0067 — L'aperçu au survol de « Reprendre » est un diaporama des images de la barre

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** l'app (`app/lib/widgets/global/resume_preview/`,
  `app/lib/widgets/global/continue_watching_card.dart`, `app/lib/theme/app_motion.dart`,
  `app/lib/services/api/playback.dart`, réglage dans `screens/settings/pages/device_page.dart`)
  et le serveur (`server/streaming/previews.go`, paramètre `warm=0`).
- **S'écarte du contrat de mouvement** (`PROJECT_DESIGN.md` §10, 180–280 ms) pour un seul token,
  `AppMotion.ambient`, parce que ce n'est pas une transition.

## Contexte

Laisser la souris sur une carte « Reprendre » devait l'agrandir comme sur Netflix : un extrait,
le titre, l'épisode, le temps restant et le résumé. Trois façons de montrer « l'extrait » :

1. un vrai lecteur dans la carte (mpv, ExoPlayer ou AetherEngine en petit) ;
2. un court clip généré et mis en cache par le serveur ;
3. une suite d'images fixes prises autour du point d'arrêt.

Le lecteur ouvre une session de lecture, parfois un transcodage, à chaque survol, et se dispute
les surfaces vidéo natives avec le lecteur principal. Le clip demande un nouvel encodage par
média. Le serveur, lui, sait déjà extraire une image clé à la demande pour la barre de lecture
(40 à 170 ms selon le fichier).

## Décision

1. **Les images de la barre de lecture.** L'aperçu demande un ticket de lecture, le manifeste
   des images, puis six images couvrant les deux minutes et demie avant l'arrêt, la dernière
   étant celle où l'on s'est arrêté. Un média pas commencé montre son ouverture (après 30 s de
   logos). Le ticket est rendu à la fermeture.
2. **`warm=0`.** La demande de manifeste de l'aperçu ne lance pas la passe de fond : elle
   prendrait l'une des deux places et chasserait celle d'un spectateur en pleine lecture.
3. **Souris seulement, sur ordinateur et navigateur**, après 700 ms d'attente. Un téléphone n'a
   pas de survol ; un téléviseur garde son focus pour naviguer. Réglage « Aperçu au survol »
   dans « Cet appareil », activé d'office.
4. **Le panneau vit dans l'Overlay de la route** (`OverlayPortal` + `CompositedTransformFollower`),
   centré sur l'affiche et ramené dans l'écran : il ne pousse pas la rangée, n'est pas coupé par
   la liste, et une page poussée par-dessus le recouvre.
5. **`AppMotion.ambient` (2,6 s)** porte la lente avancée de chaque image, ce qui la fait lire
   comme un extrait. Elle passe toujours par `AppMotion.move`, donc tombe à zéro sous « réduire
   les animations ». Les fondus entre images restent dans le contrat (`emphasis`).

## Conséquences

- Aucun encodage ni stockage nouveau côté serveur ; les images extraites rejoignent le cache
  des images de barre, déjà borné.
- Un serveur sans images de barre, ou qui refuse le ticket, laisse l'aperçu sur l'affiche : le
  résumé et les boutons restent.
- Un vrai clip (option 2) reste possible plus tard sans toucher au panneau : seul
  `ResumePreviewStills` changerait de source.
- Le focus TV n'ouvre pas l'aperçu. Le faire demanderait de décider où il s'affiche pendant que
  le focus se déplace.
