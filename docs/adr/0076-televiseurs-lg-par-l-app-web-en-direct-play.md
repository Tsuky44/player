# ADR-0076 — Les téléviseurs LG ouvrent l'app web du serveur, et la lisent en Direct Play

- **Statut :** accepté, non encore essayé sur un téléviseur
- **Date :** 2026-10-20
- **Portée :** `app/webos/` (le lanceur), `scripts/build-webos.*`,
  `app/lib/screens/player/playback/webos_playback_session*.dart`,
  `PlaybackCapabilities.webOS` (`app/lib/services/playback_capabilities.dart`),
  `AppPlatform.isWebOS`, `app/lib/tv/webos_remote*.dart`, la connexion TV dans `main.dart` et
  `login_screen.dart`.
- **Complète** l'ADR-0014 (capacités déclarées) et l'ADR-0020 (appairage serveur sur le web).

## Contexte

Les téléviseurs LG tournent sous webOS. Flutter n'y a pas de moteur natif utilisable : le
portage de LG ne vise que les modèles les plus récents, alors qu'un parc de téléviseurs vit dix
ans. Ce que tous les modèles ont, c'est un moteur web (Chromium) et un pipeline multimédia
matériel — celui du lecteur USB intégré, qui lit le Matroska, le HEVC 10 bits, le HDR10 et le
Dolby Digital Plus.

Le web d'Onyx, tel quel, ne s'en sert pas : il transcode toujours (`_hlsOnly`), parce qu'un
onglet de bureau ne lit pas un Matroska et compose en 8 bits. Sur un téléviseur, c'est
transcoder pour rien un fichier que l'écran sait lire, au prix du CPU du serveur, du HDR et du
5.1.

## Décision

### 1. Le paquet webOS est un lanceur, l'app est celle que sert le serveur

Le `.ipk` ne contient qu'une page (`app/webos/index.html`) : elle retient l'adresse du serveur,
vérifie `GET /api/ping`, puis ouvre `http://serveur:port/` — l'app web que le serveur embarque
déjà (`server/webui`). Écartée : empaqueter le bundle Flutter dans l'`.ipk`. Il faudrait
republier le paquet à chaque version, charger CanvasKit et ses `.wasm` depuis `file://`, et
parler au serveur depuis une origine nulle. Le lanceur, lui, ne change presque jamais, et
l'app est toujours de la version du serveur.

Le lanceur laisse 1,5 s pour « Changer de serveur » avant d'ouvrir celui qu'il connaît.

### 2. L'app reconnaît webOS à son agent utilisateur

`AppPlatform.isWebOS` lit « Web0S » dans l'agent utilisateur ; la page n'a accès à aucune API
du système. Il allume le mode TV (`TvMode`), choisit la session de lecture et les capacités.

### 3. Direct Play par un `<video>` qui reçoit le fichier

`WebOSPlaybackSession` donne au `<video>` l'URL du fichier, comme ExoPlayer ou AetherEngine.
Sur webOS, une source ouverte par `src` part dans le pipeline du téléviseur — décodeurs
matériels, plan vidéo sous la page — et non dans le décodeur logiciel de Chromium. media_kit
n'est pas utilisé : son backend web ne change pas de piste audio dans un fichier, alors que
webOS expose `audioTracks`.

- **Pistes audio** : changées sur place par `audioTracks` ; la n-ième du serveur est la
  n-ième de l'élément.
- **Sous-titres** : une page ne voit pas ceux du fichier. Ils viennent des WebVTT du serveur,
  comme sur le reste du web (`_readsEmbeddedSubtitles`).
- **Refus** : une erreur 3 ou 4 de l'élément est un `unsupported`, que le contrôleur rattrape
  déjà par un repli HLS. Chromium répond aussi 4 à une réponse HTTP en erreur ; le HLS échoue
  alors à son tour, comme une vraie panne.
- **Repli HLS** : par le même élément, avec hls.js et la passerelle `WebPlayback` existante.

### 4. Ce que le téléviseur déclare

`PlaybackCapabilities.webOS` : ce que `MediaSource` répond pour les segments, mais 6 canaux et,
si le HEVC Main 10 passe, 10 bits et HDR — le plan vidéo d'un téléviseur n'est pas la surface 8
bits d'un onglet. Les pistes que le Direct Play laisserait muettes viennent de `canPlayType` :
le DTS (absent des modèles 2020 à 2022), le TrueHD et l'AC-4 partent en HLS quand l'élément ne
les annonce pas. Le Dolby Vision n'est jamais supposé : un profil 5 part en HLS (ADR-0060).

### 5. Télécommande et connexion

- Les touches propres à LG n'arrivent qu'avec leur `keyCode`. `WebOSRemote` les réécrit avant
  Flutter : Retour (461) en Échap, que l'habillage TV traite déjà comme un retour, et les
  touches de lecture en `Media*`. `disableBackHistoryAPI` empêche webOS de reculer dans
  l'historique.
- Les raccourcis par défaut de Flutter Web sont ceux d'une page : les flèches font défiler, et
  Entrée n'active que les boutons. En mode TV sur le web, `webTvShortcuts` (`tv_focus.dart`)
  rend aux flèches leur sens de D-pad (`DirectionalFocusIntent`) et à OK l'activation.
- Le verre du chrome n'y floute pas (`glassBlurs`, `glass_chrome.dart`) : sur le GPU d'un
  téléviseur, le flou plein écran de l'en-tête, refait à chaque image, faisait ramer l'accueil.
  Il devient un voile plus opaque.
- La connexion TV par lien local (ADR-0007) demande d'écouter sur une socket, ce qu'une page ne
  peut pas faire. Sur webOS, l'écran de connexion propose donc l'appairage serveur de
  l'ADR-0020, à côté du formulaire.

## Conséquences

- Un téléviseur LG lit en Direct Play ce que son lecteur USB lit, sans charge serveur, HDR10 et
  5.1 compris. Ce qu'il refuse retombe en HLS sans geste de l'utilisateur.
- Un changement de l'app web n'atteint les téléviseurs qu'une fois le serveur reconstruit avec
  le nouveau bundle (`scripts/build-web.*`). Le lanceur se publie à part : chaque Release porte
  `Onyx-<version>-webos.ipk` (job `build-webos`), installé en mode développeur
  ([`docs/webos.md`](../webos.md)).
- hls.js vient de cdnjs, comme partout où media_kit le charge : un téléviseur sans accès à
  Internet a le Direct Play mais pas le repli HLS.
- Retour à l'accueil de l'app ne quitte pas : c'est la touche Accueil du téléviseur qui le fait.
- Cible : webOS 6 (2021) et après, dont le Chromium fait tourner CanvasKit. Rien de ceci n'a
  encore été vu sur un téléviseur : les capacités, le Direct Play du Matroska par `src` et le
  nom des touches sont à confirmer sur un appareil, d'où le statut.
