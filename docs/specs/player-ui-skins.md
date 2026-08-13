# Bibliothèque de skins visuels pour Player Studio (Flat + Néomorphique)

## Problem Statement

Tous les presets de lecteur (Player Studio) partagent aujourd'hui un seul moteur de rendu visuel : le glassmorphisme (`ControlChrome`). Les réglages exposés (flou, opacité, effet liquide) ne font que varier l'intensité de ce même verre — il n'existe aucun moyen de donner à un preset un langage visuel réellement différent. Le porteur du produit veut que chaque utilisateur final de l'app (qui remplace Plex) puisse choisir un lecteur avec une identité visuelle qui lui convient, pas seulement une disposition de boutons différente sur le même style de verre.

## Solution

Introduire deux nouveaux langages visuels de contrôles ("skins") — **Flat/Material** et **Néomorphique** — comme alternative au skin Verre existant. Le skin est un réglage par preset (pas par bouton) qui s'applique à la fois aux contrôles individuels et à la barre de timeline. Deux nouveaux templates prêts-à-l'emploi, **« Net »** (Flat) et **« Doux »** (Néomorphique), sont ajoutés au catalogue « Choisir un modèle » à côté de Cinéma/Séries/Pro/Classique. Le skin devient aussi réglable après-coup dans le Studio, pour n'importe quel preset existant ou personnalisé, via une extension du drawer de style actuel (`GlassStyleDrawer`).

## User Stories

1. En tant qu'utilisateur du Studio, je veux choisir entre le style Verre, Flat et Néomorphique dans le drawer de style, afin de donner à mon lecteur personnalisé une identité visuelle distincte du glassmorphisme par défaut.
2. En tant qu'utilisateur parcourant « Choisir un modèle », je veux voir « Net » et « Doux » à côté de Cinéma/Séries/Pro/Classique, afin de découvrir les nouveaux styles sans chercher un réglage caché.
3. En tant qu'utilisateur ayant choisi « Net », je veux que tous les boutons ET la timeline rendent dans le style flat de façon cohérente, afin que le lecteur ne ressemble pas à un patchwork de styles mélangés.
4. En tant qu'utilisateur ayant choisi « Doux », je veux que la barre de progression rende aussi avec des ombres douces extrudées, afin que l'ensemble du lecteur soit cohérent visuellement.
5. En tant qu'utilisateur personnalisant un preset dans le Studio, je veux pouvoir changer de skin sur une disposition existante (positions conservées) sans perdre le placement de mes contrôles, afin d'expérimenter des looks sans reconstruire ma disposition.
6. En tant qu'utilisateur choisissant le skin Flat, je veux sélectionner une couleur d'accent dans une palette restreinte et un niveau d'élévation (aucune/légère/marquée), afin d'avoir une personnalisation limitée sans la complexité d'un color picker libre.
7. En tant qu'utilisateur choisissant le skin Néomorphique, je veux un seul curseur d'intensité contrôlant la profondeur des ombres, afin de régler l'effet « moelleux » sans jongler avec plusieurs paramètres.
8. En tant qu'utilisateur ayant déjà des presets en skin Verre, je veux qu'ils continuent de s'afficher exactement comme avant après cette évolution, afin que rien ne casse dans ma bibliothèque existante.
9. En tant que développeur, je veux que le skin soit stocké comme un champ sur `PlayerLayoutConfig` (au même niveau que `liquidGlass`/`blurIntensity`), afin que la persistance et la (dé)sérialisation JSON suivent le pattern existant.
10. En tant que développeur, je veux qu'une valeur de skin absente ou inconnue dans un JSON sauvegardé retombe par défaut sur Verre, afin de garantir la compatibilité rétroactive sans script de migration.
11. En tant qu'utilisateur regardant une vidéo avec le skin Flat ou Néomorphique sélectionné, je veux que la barre de timeline (scrubber, boutons de transport, labels de temps) suive aussi ce skin plutôt que de retomber sur le style Emby ou Verre, afin que l'ensemble du HUD soit cohérent.
12. En tant qu'utilisateur parcourant le sélecteur de modèles, je veux que chaque nouvelle carte de template (« Net », « Doux ») affiche un nom, une tagline, une description et une liste d'extras, au même format que les 4 cartes existantes, afin que le catalogue paraisse uniforme.
13. En tant qu'ingénieur QA, je veux des tests au niveau modèle confirmant que « Net » et « Doux » satisfont chaque CORE role (back, titre, lecture/pause, retour, avance, scrubber, sous-titres, réglages, plein écran), à l'image de la couverture existante pour Cinéma/Séries/Pro/Classique, afin de détecter les régressions sans nouvelle infrastructure de test widget.
14. En tant que développeur, je veux que l'aller-retour JSON (encode/decode) du champ skin soit couvert par un test unitaire, afin qu'un futur refactor ne fasse pas disparaître le champ silencieusement.
15. En tant qu'utilisateur sur desktop/mobile/TV, je veux que les skins Flat et Néomorphique respectent les mêmes bornes de `modularControlPixelSize` que Verre, afin que la taille des boutons reste cohérente entre appareils quel que soit le skin.
16. En tant qu'utilisateur, je veux que la disposition du template « Net » soit réellement distincte des 4 dispositions existantes (pas une simple recoloration), afin que le catalogue ne paraisse pas redondant.
17. En tant qu'utilisateur, je veux que la disposition du template « Doux » laisse plus d'espace entre les contrôles que « Net », afin que l'effet d'extrusion néomorphique soit visible et ne paraisse pas tassé.
18. En tant qu'utilisateur, je veux que l'état du skin soit correctement persisté quand je sauvegarde un preset personnalisé sur le serveur, afin de retrouver le même look en rouvrant l'app sur un autre appareil (le backend stocke un blob JSON opaque, donc aucun changement serveur n'est requis, mais le champ doit être écrit et lu côté client).

## Implementation Decisions

- Nouvel enum `ControlSkinStyle` : `glass` / `flat` / `neumorphic`. Ajouté comme champ sur `PlayerLayoutConfig` (défaut `glass`), au même niveau que `blurIntensity`/`glassOpacity`/`liquidGlass` — suit le pattern existant, avec une clé JSON ajoutée à `toJson`/`fromJson` et un fallback sûr sur `glass` si la clé est absente (configs anciennes).
- Nouveaux paramètres par skin, volontairement minimaux :
  - **Flat** : une couleur d'accent choisie dans une palette prédéfinie restreinte (pas de color picker libre), et un niveau d'élévation (aucune/légère/marquée) — 2 réglages, stockés sur `PlayerLayoutConfig` de la même façon que les paramètres du verre.
  - **Néomorphique** : un seul curseur d'intensité contrôlant la profondeur/l'extrusion des ombres ; la teinte de base est dérivée du fond existant, non sélectionnable par l'utilisateur.
- `ControlChrome` (seam de rendu unique, appelé depuis les 3 mêmes points : canvas du Studio, overlay de lecture live, miniature d'aperçu du Studio) gagne deux nouvelles branches de rendu en plus du chemin existant `_simpleGlass`/`_liquidGlass`, sélectionnées par le nouveau champ skin — le skin Verre garde son comportement actuel de flou/opacité/liquide inchangé.
- L'enum `TimelineVisualStyle` (actuellement `glass`/`emby`) gagne deux entrées — `flat` et `neumorphic` — avec de nouvelles méthodes de construction de barre de timeline dans `ControlChrome` (en parallèle des `_buildGlassTimelineBar`/`_buildEmbyTimelineBar`/`_buildGlassInlineTimelineBar` existantes), en réutilisant la même logique de disposition (boutons de transport, labels de temps, track) mais en changeant la décoration du conteneur pour matcher chaque skin.
- Deux nouvelles entrées ajoutées à `PlayerLayoutTemplates.all` : **« Net »** (skin Flat, disposition en barre basse dense, CORE roles uniquement) et **« Doux »** (skin Néomorphique, disposition centrée avec espacement supplémentaire entre les contrôles). Chacune a sa propre valeur d'enum `PlayerTemplateId`, son nom/tagline/description/icône, et une fonction `build()` suivant le pattern des helpers `_btn`/`_bar` existants ; les deux doivent passer `buildValidated()` (CORE roles présents).
- Le `GlassStyleDrawer` existant est étendu en un drawer de style général : un sélecteur de skin (Verre/Flat/Néomorphique) en haut, avec les curseurs/interrupteurs en dessous qui changent selon le skin sélectionné (Verre garde flou/opacité/liquide ; Flat affiche la pastille de couleur + l'élévation ; Néomorphique affiche le curseur d'intensité unique). Ce drawer est accessible depuis le Studio pour n'importe quel preset — nouveau ou déjà existant —, pas seulement les deux nouveaux templates.
- Aucun changement backend/API/schéma : le serveur persiste `PlayerLayoutConfig.toJson()` comme un blob JSON opaque (colonne `config_json`, seulement validée comme JSON bien formé) — le nouveau champ skin est transporté automatiquement dès que le modèle Flutter le sérialise.
- Compatibilité rétroactive : toute config sauvegardée sans la clé skin retombe sur `glass`, à l'image du pattern déjà utilisé pour d'autres champs introduits après coup (ex. `tap_to_toggle_playback`).

## Testing Decisions

- Tests au niveau modèle uniquement, dans le style du fichier existant `app/test/player_layout_templates_test.dart` (pas de tests widget/golden de rendu — aucun précédent de ce type n'existe dans ce repo, et les régressions purement visuelles sont mieux détectées par vérification manuelle que par des tests pixel fragiles).
- Étendre ce fichier (ou un fichier de test voisin) pour couvrir :
  - `PlayerLayoutTemplates.all` contient désormais 6 entrées (au lieu de 4) ; chaque entrée (y compris « Net » et « Doux ») passe toujours `buildValidated()` / `satisfiesCoreRoles`.
  - « Net » et « Doux » exposent chacun un ensemble de contrôles distinct des 4 autres templates (disposition non-triviale, pas un doublon).
  - Aller-retour JSON de `PlayerLayoutConfig` : `encode()` → `decode()` préserve le champ skin et ses paramètres associés, pour les trois valeurs de skin.
  - Décoder un JSON sans clé skin retombe par défaut sur `ControlSkinStyle.glass` (compatibilité rétroactive).
- Précédent : `app/test/player_layout_templates_test.dart` est le précédent direct — mêmes blocs `test()` simples contre la couche modèle, sans montage de widget Flutter.

## Out of Scope

- Tests widget/golden de rendu pour les nouvelles branches de skin dans `ControlChrome` ou les nouveaux builders de timeline.
- Nouveaux styles de timeline au-delà de Flat et Néomorphique (Verre et Emby restent inchangés).
- Skins additionnels au-delà de Flat et Néomorphique (Néon, Rétro, Ghost, etc.) — évoqués pendant le grilling mais explicitement reportés.
- Mélange de skins par bouton (un preset, plusieurs skins) — écarté en faveur d'un skin unique par preset.
- Changements de schéma backend/base de données — aucun nécessaire, le stockage JSON opaque encaisse le nouveau champ.
- Une interface/architecture de skin généralisée et pluggable — cette itération livre deux skins concrets câblés directement dans `ControlChrome` ; une abstraction générique de plugin est explicitement reportée jusqu'à ce que plus de skins confirment le pattern.
- Nouveaux templates ciblant des profils utilisateurs (enfants, accessibilité, TV/10-foot, etc.) — la demande initiale a été recadrée pendant le grilling comme un problème de style visuel, pas de couverture de profils.

## Further Notes

- Cette spec est l'aboutissement d'une session `/grill-me` : le problème a d'abord été formulé comme « pas assez de profils de lecteurs », puis recadré, après inspection de `control_chrome.dart`, comme « un seul moteur de rendu (glassmorphisme) existe » — la correction cible la couche de rendu, pas la largeur du catalogue de templates.
- Les noms « Net » et « Doux » suivent la convention existante de noms français courts en un mot (Cinéma/Séries/Pro/Classique).
- Si les styles de timeline Flat/Néomorphique s'avèrent visuellement décevants une fois construits, reconsidérer la décision de leur donner des builders de timeline dédiés plutôt que de retomber sur le style Emby existant (ce point a été explicitement discuté ; l'utilisateur a choisi la voie complète).
