# Fiche Google Play — Onyx

Tout ce qu'il faut coller ou téléverser dans Play Console > Présence sur le Play Store >
Fiche Play Store par défaut. Les visuels sont dans [`out/`](out/), leurs sources dans [`src/`](src/).

Règle suivie partout : aucun contenu commercial. Les affiches, fonds et titres sont des
illustrations générées pour l'occasion (films fictifs), la musique de la vidéo est synthétisée.
Rien n'appartient à un tiers, rien n'est à créditer.

---

## Éléments textuels — français (fr-FR, langue par défaut)

### Nom de l'application (30 car. max)

```
Onyx : lecteur multimédia
```

25 caractères. Le mot « lecteur multimédia » aide la recherche sans bourrage de mots-clés.
Variante plus courte si tu préfères la marque seule : `Onyx`.

### Brève description (80 car. max)

```
Tes films et séries, sur ton propre serveur. Direct Play, hors ligne, ensemble
```

78 caractères.

### Description complète (4 000 car. max)

```
Onyx transforme la médiathèque de ton propre serveur en un vrai cinéma privé. Tes films et tes séries, avec leurs affiches, leurs fiches et ta progression, sur ton téléphone, ta tablette et ta TV.

Onyx est un lecteur : il se connecte à un serveur Onyx que tu installes toi-même, chez toi ou sur ta machine, et sur lequel tu ajoutes tes propres fichiers. L'app ne fournit, n'héberge et ne vend aucun contenu.

■ LA QUALITÉ D'ORIGINE, SANS COMPROMIS
• Direct Play : ton fichier est lu tel quel, sans transcodage ni perte de qualité
• 4K, HDR et son multicanal, selon ce que ton appareil sait décoder
• Avance et retour instantanés, aperçus sur la barre de lecture
• Transcodage de secours quand un format n'est pas pris en charge

■ UNE MÉDIATHÈQUE QUI DONNE ENVIE
• Films et séries classés automatiquement, saisons et épisodes compris
• Affiches, résumés, casting et collections ajoutés tout seuls
• Recherche, listes personnelles et « Reprendre la lecture » en page d'accueil
• Les nouveaux fichiers apparaissent dès qu'ils arrivent sur le serveur

■ UN LECTEUR PENSÉ POUR LES SÉRIES ET LES FILMS
• Pistes audio et sous-titres au choix, en un geste
• Dialogues mis en avant pour les films au mixage chargé
• Saut d'intro et épisode suivant automatique
• Image dans l'image pour continuer à regarder en faisant autre chose
• Réglages des sous-titres et du format d'image

■ REPRENDS LÀ OÙ TU T'ES ARRÊTÉ
• Ta progression est synchronisée entre tous tes appareils
• Commence un film sur ta TV, finis-le sur ton téléphone

■ REGARDEZ ENSEMBLE
• Lance une séance et partage son code
• Pause, lecture et avance rapide synchronisées en temps réel pour tous les participants

■ HORS LIGNE
• Télécharge films et épisodes pour les regarder sans connexion
• Option Wi-Fi uniquement pour préserver ton forfait

■ TA FAMILLE, TES RÈGLES
• Le premier compte est propriétaire du serveur, les autres rejoignent sur invitation
• Permissions fines pour chaque membre
• Connexion d'une TV par QR code, sans taper de mot de passe

■ PARTOUT
Android, Android TV, iOS, Apple TV, Windows, macOS et navigateur web.

■ TES DONNÉES RESTENT CHEZ TOI
Aucun compte cloud, aucune publicité. Ta bibliothèque, ta progression et tes comptes vivent sur ton serveur.

À SAVOIR
Un serveur Onyx auto-hébergé est nécessaire. L'app ne contient aucun catalogue, aucun lien vers du contenu et aucun serveur par défaut. Tu es responsable de ton serveur, de tes fichiers et des droits qui s'y rattachent.

Onyx est en bêta : tout est gratuit aujourd'hui. Les métadonnées et les affiches proviennent de TMDB. Ce produit utilise l'API TMDB mais n'est ni approuvé ni certifié par TMDB.
```

---

## Éléments textuels — anglais (en-US, à ajouter comme traduction)

### App name

```
Onyx: Media Player
```

### Short description

```
Your movies and shows, on your own server. Direct Play, offline, watch together.
```

### Full description

```
Onyx turns the media library on your own server into a private cinema. Your movies and TV shows, with posters, details and your progress, on your phone, tablet and TV.

Onyx is a player: it connects to an Onyx server that you set up yourself, at home or on your own machine, and fill with your own files. The app does not provide, host or sell any content.

■ ORIGINAL QUALITY, NO COMPROMISE
• Direct Play: your file plays as is, with no transcoding and no quality loss
• 4K, HDR and multichannel audio, depending on what your device can decode
• Instant seeking with thumbnail previews on the timeline
• Fallback transcoding when a format is not supported

■ A LIBRARY THAT MAKES YOU WANT TO WATCH
• Movies and shows sorted automatically, seasons and episodes included
• Posters, synopses, cast and collections added for you
• Search, personal lists and "Continue watching" on the home screen
• New files show up as soon as they land on the server

■ A PLAYER BUILT FOR MOVIES AND SHOWS
• Pick audio and subtitle tracks in one tap
• Dialogue boost for busy mixes
• Skip intro and auto-play next episode
• Picture-in-picture to keep watching while you do something else
• Subtitle and aspect-ratio settings

■ PICK UP WHERE YOU LEFT OFF
• Your progress syncs across all your devices
• Start a movie on your TV, finish it on your phone

■ WATCH TOGETHER
• Start a session and share its code
• Pause, play and seek stay in sync for everyone, in real time

■ OFFLINE
• Download movies and episodes to watch without a connection
• Wi-Fi only option to protect your data plan

■ YOUR HOUSEHOLD, YOUR RULES
• The first account owns the server, others join by invitation
• Fine-grained permissions for every member
• Sign a TV in with a QR code, no password typing

■ EVERYWHERE
Android, Android TV, iOS, Apple TV, Windows, macOS and the web.

■ YOUR DATA STAYS HOME
No cloud account, no ads. Your library, progress and accounts live on your server.

GOOD TO KNOW
A self-hosted Onyx server is required. The app contains no catalog, no links to content and no default server. You are responsible for your server, your files and the related rights.

Onyx is in beta: everything is free today. Metadata and artwork come from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.
```

---

## Éléments visuels

Les écrans d'Onyx sont redessinés à l'identique de l'app ([`src/screens.html`](src/screens.html),
rendus dans [`screens/`](screens/)) puis posés sur un téléphone modélisé dans Blender
([`renders/`](renders/)), avec les affiches des films libres qui sortent de l'écran.

| Champ Play Console | Fichier | Format |
|---|---|---|
| Icône | `out/icone-512.png` | 512 x 512 |
| Image de présentation | `out/image-presentation-1024x500.png` | 1024 x 500 |
| Vidéo | `out/video-presentation-1920x1080.mp4` | 26 s, à mettre sur YouTube |
| Captures téléphone (5) | `out/telephone-1-…` à `out/telephone-5-…` | 1080 x 1920 |
| Captures tablette 7" et 10" (2) | `out/tablette-1-…`, `out/tablette-2-…` | 2560 x 1440 |

### Crédits des médias (à garder dans la description ou la fiche)

Films affichés dans les visuels, tous réutilisables commercialement avec attribution :
Meridian (2016) © Netflix, CC BY 4.0 · Tears of Steel (2012), Sintel (2010), Cosmos Laundromat (2015),
Spring (2019), Sprite Fright (2021), Charge (2022) © Blender Foundation, CC BY.
Affiches et résumés : TMDB. Musique de la vidéo : composée pour Onyx (générée par `src/music.py`).

### La vidéo sur YouTube

1. Mets `video-presentation-1920x1080.mp4` en ligne sur YouTube, en **Non répertoriée**
   ou Publique (pas Privée : Google Play ne peut pas la lire).
2. Désactive la monétisation : Google refuse les vidéos avec publicité.
3. Pas de restriction d'âge.
4. Colle l'URL au format `https://www.youtube.com/watch?v=…` dans le champ Vidéo.

---

## Le reste de la fiche (autres pages de Play Console)

- **Catégorie** : Application > Lecteurs et éditeurs vidéo.
- **Tags** : Lecteur vidéo, Streaming, Divertissement (choisis-en jusqu'à 5 dans la liste).
- **Coordonnées** : adresse e-mail de contact obligatoire, site facultatif.
- **Politique de confidentialité** : https://tsuky44.github.io/player/confidentialite.html
- **Notes pour l'examen** : voir [`docs/store-listing.md`](../../store-listing.md), section
  « Notes de review » (serveur et compte de démo à fournir).

## Régénérer les visuels

```bash
cd docs/store/google-play/src
npm i puppeteer-core          # une fois ; Edge ou Chrome doit être installé
node render-screens.cjs       # écrans d'Onyx -> ../screens
```

Ensuite, dans Blender (via le MCP) : le téléphone prend `screens/*.png` comme texture d'écran et
rend chaque mise en scène dans `renders/` (fond transparent, ombre portée seule).

```bash
node render.cjs               # visuels finaux -> ../out
python music.py 28            # musique de la vidéo
node render-video.cjs         # vidéo ; MEDIA_DIR = dossier des films libres, FFMPEG si absent du PATH
```
