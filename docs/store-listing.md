# Fiches stores et notes de review — Onyx

Brouillon à adapter (nom, URLs, identifiants de démo). Principe : tout est déclaré, rien n'est caché.

## Description courte (Google Play, 80 car.)

Onyx : le lecteur de ta médiathèque personnelle, sur ton propre serveur.

## Sous-titre App Store (30 car.)

Ta médiathèque, ton serveur

## Description (FR)

Onyx est un lecteur pour la médiathèque hébergée sur ton propre serveur.

Onyx ne fournit, n'héberge et ne vend aucun contenu. Un serveur Onyx auto-hébergé est requis : tu le déploies toi-même et tu y ajoutes tes propres fichiers.

FONCTIONNALITÉS
• Parcours ta bibliothèque de films et de séries, avec affiches et métadonnées
• Reprends la lecture là où tu t'étais arrêté, sur tous tes appareils
• Choix de la piste audio et des sous-titres, saut d'intro, épisode suivant
• Lecture directe, sans transcodage côté serveur
• Contrôles du lecteur personnalisables
• Demandes (optionnel) : si tu as connecté ton propre service de gestion de médiathèque dans les Paramètres, tu peux lui envoyer des demandes depuis l'app. Sans cette connexion, l'onglet n'apparaît pas.

CONFIDENTIALITÉ ET RESPONSABILITÉ
L'app ne contient aucun catalogue, aucun lien vers du contenu et aucun serveur par défaut. Tu es responsable de ton serveur, de tes fichiers et des droits associés. Les métadonnées et affiches proviennent de TMDB. Ce produit utilise l'API TMDB mais n'est ni approuvé ni certifié par TMDB.

## Description (EN)

Onyx is a player for the media library hosted on your own server.

Onyx does not provide, host or sell any content. A self-hosted Onyx server is required: you deploy it yourself and add your own files.

FEATURES
• Browse your movie and TV library with posters and metadata
• Resume playback where you left off
• Audio and subtitle track selection, intro skip, next episode
• Direct play, no server-side transcoding
• Customizable player controls
• Requests (optional): if you connected your own media-management service in Settings, you can send requests to it from the app. Without that connection the tab is not shown.

You are responsible for your server, your files and the related rights. Metadata and artwork come from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.

## Notes de review (App Review Notes / Google Play)

Onyx is a client app for a self-hosted personal media server. It does not provide, host, link to or sell any media. There is no default server and no built-in catalog.

How to test:
1. Launch the app and enter the demo server URL: <URL_DEMO>
2. Sign in with: <USER_DEMO> / <PASSWORD_DEMO>
3. The demo library contains only freely licensed content (Blender Foundation open movies, e.g. Big Buck Bunny, Sintel; public domain / Creative Commons).

About the "Requests" tab:
- It is hidden by default. It only appears if the user enters, in Settings > Integrations, the URL and API key of their own media-management service.
- The app has no default service and no preconfigured address. What the user requests and from where is entirely up to them, exactly like a Jellyfin client with a Seerr integration.
- For review, a demo requests service is connected on the demo account: <URL_DEMO_REQUESTS>. It is limited to open-license titles.

Content responsibility: users are responsible for their own server, files and rights (stated in the app description and in Settings > About).

Comparable apps already on the App Store: JellyTV (Jellyfin client with Seerr integration, id6752357290).

Contact: <EMAIL_CONTACT>

## Checklist avant soumission

- [ ] Serveur de démo public avec uniquement du contenu libre
- [ ] Compte de démo qui reste valide pendant toute la review
- [ ] Captures d'écran avec du contenu libre (pas d'affiches de films commerciaux)
- [ ] Mention de responsabilité et attribution TMDB dans Paramètres > À propos
- [ ] Politique de confidentialité en ligne (URL obligatoire)
- [ ] Onglet Demandes masqué tant qu'aucun service n'est connecté (à vérifier dans l'app)
- [ ] Plan B : flag `STORE_BUILD` qui masque Demandes et intégrations
- [ ] Google Play : test fermé (12 testeurs, 14 jours) pour un compte individuel neuf
