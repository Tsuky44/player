# Feuille de route — rapprocher Onyx de Plex et Emby

État de référence : commit `d86d10ec2f9cc435f94fb5552b6185e889167878`, 12 septembre 2026.

Suivi de réalisation : [banc de validation et résultats datés](validation-lecture.md). Phase 0 commencée ; les résultats automatiques ne valent pas validation sur appareils réels.

Phase 1 : [tickets implémentés localement, compatibilité et validation](playback-tickets.md). Tests automatiques réussis ; déploiement et validation sur moteurs réels en attente. Les phases 2 à 8 restent à implémenter.

## Objectif

Faire d'Onyx un lecteur multimédia privé aussi fiable et agréable au quotidien que Plex ou Emby, sans perdre ses différences : serveur léger, Direct Play prioritaire, confidentialité, Player Studio et prise en charge poussée de mpv.

Le travail porte sur le parcours `bibliothèque → fiche → lecture → changement d'appareil → reprise`. La musique, les photos, la télévision en direct et le DVR ne font pas partie de cette feuille de route.

## Principes à préserver

- Le Direct Play reste le premier choix lorsque le client sait lire la source.
- Le serveur détermine le chemin de lecture depuis `streaming.Capabilities`, `PlanVideo` et `PlanAudio` ; aucune seconde logique de compatibilité ne doit apparaître ailleurs.
- Une perte de réseau, une erreur de transcodage ou une piste incompatible doit produire un message et une action de récupération, jamais un spinner infini.
- La progression reste propre à l'utilisateur et la plus récente gagne lors d'une synchronisation.
- Les fonctionnalités hors ligne ne doivent pas dépendre du serveur après le téléchargement.
- Les modifications du lecteur doivent rester compatibles avec les chromes standard, Emby et Player Studio.

## État existant à conserver

- Direct Play, HLS et transcodage de secours.
- Déclaration des capacités du client, HDR et tone mapping SDR.
- Dolby Vision via `gpu-next` sur macOS.
- Audio multicanal, sous-titres internes, externes et image.
- Reprise, progression, lecture automatique, épisode précédent/suivant.
- Détection des intros/outros et navigation par chapitres.
- Qualité manuelle de 360p à 2160p.
- Téléchargements hors ligne et synchronisation différée de progression.
- Télécommande Android TV, touches multimédias desktop et appairage TV.
- Picture-in-Picture Android et correspondance de fréquence sur Android TV.
- Plusieurs serveurs, invitations, droits et Player Studio.

## Vue d'ensemble

| Phase | Priorité | Résultat | Dépend de |
| --- | --- | --- | --- |
| 0 | P0 | Mesures et matrice de lecture reproductibles | — |
| 1 | P0 | Flux vidéo authentifiés par jetons temporaires | Phase 0 |
| 2 | P0 | Qualité automatique selon le réseau et le buffer | Phases 0–1 |
| 3 | P1 | « Lire sur… » et téléphone utilisé comme télécommande | Phase 1 |
| 4 | P1 | Profils de foyer et contrôle parental | Phase 1 |
| 5 | P1 | Téléchargements fiables en arrière-plan | Phases 1–2 |
| 6 | P2 | Miniatures de recherche temporelle et préférences de lecture | Phase 0 |
| 7 | P2 | Files, favoris, versions et bonus | Phase 4 |
| 8 | P2 | Administration des sessions et observabilité | Phases 1–2 |

---

## Phase 0 — Banc de qualité de lecture

### But

Pouvoir prouver qu'une modification améliore la lecture sans casser un codec, une plateforme ou une reprise.

### Travail

- Définir une petite médiathèque de test couvrant au minimum : H.264 SDR, HEVC HDR10, Dolby Vision profils 5 et 8, AV1, audio AAC, AC-3, E-AC-3/Atmos, TrueHD, DTS, sous-titres SRT/ASS/PGS et plusieurs pistes audio.
- Documenter le résultat attendu par plateforme : macOS arm64/x86_64, Windows, Android mobile, Android TV, iOS et web.
- Mesurer pour chaque scénario : temps avant première image, changements de qualité, seek court/long, images perdues, avance du buffer, reprise après coupure et désynchronisation audio/vidéo.
- Ajouter des tests d'intégration pour les décisions `PlanVideo`/`PlanAudio`, les playlists HLS et les changements de piste.
- Ajouter des tests widget pour le HUD, le scrubber, les menus audio/sous-titres/qualité et les erreurs de démarrage.
- Écrire une procédure de validation sur appareils réels pour PiP, HDR, fréquence d'affichage et télécommande.

### Zones principales

- `server/streaming/`
- `app/lib/screens/player/`
- `packages/onyx_player_android/`
- `packages/onyx_mpv_macos/`
- `app/test/`

### Terminé quand

- Chaque format de la matrice a un chemin attendu clairement identifié : Direct Play, remux ou transcodage.
- Les régressions de démarrage, seek, piste audio, sous-titres et progression sont détectées automatiquement.
- Les validations qui exigent un appareil réel ont une checklist datée et reproductible.

---

## Phase 1 — Sécuriser les URL de lecture

### Problème

`/stream`, les sessions HLS et les fichiers de sous-titres sont accessibles sans authentification afin que mpv, ExoPlayer et les lecteurs web puissent les charger directement. Cette compatibilité doit être conservée sans exposer une URL durable.

### Conception cible

Le client authentifié demande un ticket de lecture. Le serveur renvoie une URL portant un jeton opaque, limité à un utilisateur, un média et une durée courte. Toutes les playlists, segments et sous-titres de la session héritent de cette autorisation.

### Travail

- Ajouter une table ou un store mémoire de tickets avec : hash du jeton, utilisateur, média, expiration, dernière activité et révocation.
- Ajouter un endpoint authentifié de création de ticket.
- Vérifier le ticket sur `/stream`, les routes HLS et les sous-titres.
- Faire transmettre le jeton dans les URI des playlists enfants et segments, ou utiliser un identifiant de session HLS lui-même signé.
- Révoquer le ticket à la fermeture normale du lecteur et laisser un reaper supprimer les tickets abandonnés.
- Refuser qu'un ticket serve un autre média ou survive au-delà de son expiration.
- Masquer les jetons dans les logs et les messages de diagnostic.
- Prévoir une migration douce : client et serveur d'une même version utilisent les tickets ; documenter clairement la compatibilité avec les anciennes versions.

### Zones principales

- `server/main.go`
- `server/handlers/playback.go`
- `server/handlers/stream.go`
- `server/handlers/subtitles.go`
- `server/streaming/handler.go`
- `server/database/migrations.go`
- `app/lib/services/api_client.dart`
- `app/lib/screens/player/hooks/use_player_controller.dart`

### Tests obligatoires

- URL sans ticket, expirée, révoquée ou destinée à un autre média : refusée.
- Un ticket valide fonctionne avec Range Requests, HLS, pistes audio et sous-titres.
- Une playlist ne contient aucune URI non protégée.
- Le seek et le changement de qualité restent valides pendant la session.
- Aucun jeton en clair dans les logs de test.

### Terminé quand

- Aucun octet vidéo ou de sous-titre personnel n'est servi sans autorisation temporaire valide.
- Tous les moteurs de lecture pris en charge ouvrent les URL signées sans ajout d'en-tête personnalisé.

---

## Phase 2 — Qualité automatique et adaptation réseau

### Problème

Le menu permet uniquement de forcer Direct, 360p, 480p, 720p, 1080p ou 2160p. Une connexion instable continue donc à bufferiser jusqu'à une intervention manuelle.

### Conception cible

Ajouter un mode `Automatique` par défaut. Il choisit une qualité initiale depuis le type de réseau et les performances précédentes, puis adapte la qualité avec hystérésis : descente rapide en cas de risque de coupure, remontée lente après une période stable.

### Travail serveur

- Produire une playlist HLS réellement adaptative avec plusieurs renditions vidéo compatibles avec les capacités déclarées.
- Conserver une seule représentation copiée lorsque le Direct Play est possible et stable.
- Ajouter des plafonds séparés pour réseau local et distant.
- Exposer dans la réponse de session : chemin choisi, débit source, renditions disponibles et raison d'un transcodage.
- Limiter le nombre d'encodages simultanés et dégrader proprement lorsque le serveur est saturé.

### Travail client

- Ajouter `Automatique` aux préférences de lecture et au menu de qualité.
- Estimer le débit à partir du temps de téléchargement des segments, de l'avance du buffer et des interruptions.
- Séparer les préférences `Qualité locale`, `Qualité distante` et `Données mobiles`.
- Afficher une explication concise lorsque la qualité baisse ou qu'un transcodage est imposé.
- Autoriser le verrouillage manuel d'une qualité pour la session courante.
- Mémoriser les performances récentes par serveur et type de réseau, sans stocker d'adresse sensible dans la télémétrie.

### Zones principales

- `server/streaming/master_playlist.go`
- `server/streaming/plan.go`
- `server/streaming/ffmpeg.go`
- `server/streaming/session.go`
- `app/lib/screens/player/hooks/use_player_controller.dart`
- `app/lib/screens/player/web/web_playback_web.dart`
- `app/lib/screens/player/widgets/player_settings_sheet.dart`
- `app/lib/screens/settings/playback_preferences_screen.dart`
- `app/lib/services/playback_preferences_storage.dart`

### Tests obligatoires

- Débit insuffisant : réduction de qualité avant épuisement du buffer.
- Réseau redevenu stable : remontée graduelle sans oscillation.
- Choix manuel : aucune adaptation automatique jusqu'au retour en mode automatique.
- Direct Play local : aucun transcodage inutile.
- Serveur saturé : message exploitable et repli vers une qualité supportable.
- Audio, sous-titres, progression et position survivent au changement de rendition.

### Terminé quand

- Une limitation réseau simulée ne provoque pas de boucle de buffering continue.
- Le mode automatique reste en Direct Play sur un réseau local suffisant.
- Chaque changement de qualité conserve la position à deux secondes près et la piste choisie.

---

## Phase 3 — Lire sur un autre appareil et contrôler une TV

### But

Permettre de parcourir la bibliothèque sur un téléphone, lancer le média sur une TV Onyx et piloter la session depuis le téléphone.

### Travail

- Définir un modèle `PlaybackDevice` et un registre des appareils disponibles pour l'utilisateur.
- Ajouter un heartbeat léger des clients capables de recevoir une lecture.
- Ajouter `Lire sur…` aux fiches et au lecteur.
- Envoyer les commandes play, pause, seek, piste audio, sous-titres, volume et épisode suivant.
- Renvoyer vers le contrôleur l'état réel : média, position, durée, lecture, buffer et pistes.
- Permettre de transférer une lecture locale vers la TV puis de la reprendre sur le téléphone.
- Sécuriser chaque canal par la session utilisateur et l'appairage existant.
- Étudier Chromecast, AirPlay et DLNA après que le protocole Onyx-à-Onyx est stable ; les traiter comme adaptateurs du même modèle, pas comme un second système de contrôle.

### Zones principales

- `server/handlers/device_session.go`
- `server/handlers/device_pairing.go`
- nouveau domaine serveur `server/playbackdevices/`
- `app/lib/services/tv_link*.dart`
- `app/lib/screens/settings/tv_pairing_screen.dart`
- `app/lib/screens/player/player_screen.dart`
- fiches film et série

### Terminé quand

- Une lecture peut être lancée sur une TV appairée depuis un téléphone connecté.
- Les commandes et l'état convergent en moins d'une seconde sur le réseau local.
- La déconnexion du téléphone ne stoppe pas la TV.
- Un autre utilisateur ne peut ni voir ni contrôler la session sans autorisation.

---

## Phase 4 — Profils de foyer et contrôle parental

### But

Séparer identité d'authentification et profil de visionnage. Un compte du foyer peut contenir plusieurs profils avec progressions et restrictions distinctes.

### Travail

- Ajouter les modèles `Household`, `Profile`, `ProfileLibraryAccess` et `ProfileRestriction`.
- Attacher progression, éléments vus, préférences de langue, favoris et historique au profil actif.
- Ajouter un sélecteur de profil au démarrage et dans le menu compte.
- Ajouter un PIN haché pour les profils protégés et pour sortir d'un profil enfant.
- Restreindre les bibliothèques visibles et les classifications autorisées côté serveur.
- Appliquer les restrictions aux recherches, accueil, fiches, lecture directe, téléchargements et demandes.
- Prévoir une migration : chaque utilisateur actuel reçoit automatiquement un profil principal reprenant sa progression.
- Ajouter les permissions de téléchargement et d'accès distant par profil ou compte.

### Zones principales

- `server/models/models.go`
- `server/database/migrations.go`
- `server/handlers/users.go`
- `server/handlers/home.go`
- tous les handlers de catalogue et de lecture
- `app/lib/providers/auth_provider.dart`
- `app/lib/widgets/global/account_menu.dart`
- nouvelle surface `app/lib/screens/profiles/`

### Tests obligatoires

- Migration sans perte de progression.
- Un profil enfant ne voit pas, ne recherche pas et ne lit pas un média interdit, même en appelant directement l'API.
- Les progressions de deux profils sont indépendantes.
- Le PIN est limité en tentatives et jamais stocké ou journalisé en clair.
- Un changement de profil ferme la lecture et invalide les caches contenant des données du profil précédent.

### Terminé quand

- Toutes les routes qui retournent ou servent du contenu appliquent le profil actif côté serveur.
- Une famille peut partager un compte/appareil sans mélanger recommandations, progression et historique.

---

## Phase 5 — Téléchargements fiables

### Travail

- Déplacer la file Android vers un service de premier plan ou `WorkManager` compatible avec les contraintes du lecteur.
- Reprendre automatiquement un téléchargement interrompu avec HTTP Range.
- Ajouter les politiques : Wi-Fi uniquement, chargeur requis, plafond de stockage et emplacement Android.
- Ajouter une qualité de téléchargement et une préparation serveur lorsque l'original n'est pas lisible hors ligne.
- Autoriser film, saison, série et « prochains épisodes ».
- Rafraîchir les métadonnées locales sans retélécharger la vidéo.
- Vérifier l'espace disponible avant chaque tâche et présenter une erreur récupérable.
- Nettoyer les fichiers partiels orphelins après validation de leur absence dans la file.

### Zones principales

- `app/lib/services/download_manager_io.dart`
- `app/lib/models/offline_download.dart`
- `app/lib/screens/downloads/downloads_screen.dart`
- code Android natif de l'application
- endpoints de préparation/transcodage du serveur

### Terminé quand

- Un téléchargement reprend après fermeture forcée et redémarrage du téléphone.
- Une saison peut être mise en file en une action.
- Les limites Wi-Fi et stockage sont respectées.
- La lecture hors ligne garde pistes, sous-titres, intro/outro, affiche et progression.

---

## Phase 6 — Recherche temporelle et préférences intelligentes

### 6A. Miniatures de seek

- Générer côté serveur des miniatures espacées régulièrement et une feuille d'index temporelle.
- Mettre le résultat en cache avec une version liée au fichier source.
- Afficher la miniature et le timestamp pendant le drag sur les trois chromes.
- Précharger seulement la zone proche de la position courante sur mobile.

Terminé quand une recherche dans un film de deux heures affiche une image correspondante en moins de 100 ms après le début du drag, sans bloquer le seek.

### 6B. Audio et sous-titres

- Préférences de langues audio primaire et secondaire.
- Modes de sous-titres : jamais, forcés uniquement, lorsque l'audio diffère, toujours.
- Préférence mémorisable par série.
- Style : taille, couleur, contour, fond, position et décalage temporel.
- Conserver les préférences pendant un changement de qualité ou d'épisode.

Terminé quand le bon couple audio/sous-titres est sélectionné automatiquement sur la matrice de scénarios linguistiques, avec possibilité de corriger manuellement pour la session.

### Zones principales

- `server/indexer/`
- nouveau stockage de miniatures côté serveur
- `app/lib/screens/player/widgets/emby/emby_progress_bar.dart`
- `app/lib/widgets/global/control_chrome.dart`
- `app/lib/screens/player/widgets/modular_controls_layer.dart`
- `app/lib/screens/player/player_playback_preferences.dart`

---

## Phase 7 — Organisation personnelle et richesse du catalogue

### Travail

- Ajouter favoris et liste « À regarder » par profil.
- Ajouter une vraie file de lecture : lire ensuite, ajouter à la fin, réordonner, supprimer et reprendre sur un autre appareil.
- Ajouter playlists manuelles et lecture aléatoire.
- Modéliser plusieurs versions d'une même œuvre : édition, résolution, HDR, langue et commentaire audio.
- Choisir automatiquement la meilleure version compatible, avec sélection manuelle sur la fiche.
- Indexer et présenter bandes-annonces locales, making-of, scènes coupées et autres bonus.
- Ajouter une protection contre l'autoplay infini après une durée sans interaction.

### Terminé quand

- Favoris, liste à regarder et files sont synchronisés par profil.
- Deux fichiers du même film apparaissent comme deux versions d'une seule œuvre.
- Les bonus sont distincts du film principal et ne polluent pas les catalogues.

---

## Phase 8 — Sessions actives et diagnostic administrateur

### Travail

- Exposer les sessions actives avec utilisateur, profil, appareil, média, position, qualité et chemin Direct/remux/transcode.
- Afficher codecs, débit source/sortie, avance du buffer, images perdues et raison du transcodage.
- Afficher la consommation CPU/GPU du processus FFmpeg lorsque disponible.
- Permettre à un administrateur d'arrêter une session.
- Conserver un historique court et borné des erreurs de lecture sans enregistrer les URL signées.
- Fournir un export de diagnostic anonymisé depuis le lecteur.

### Zones principales

- `server/streaming/manager.go`
- `server/streaming/session.go`
- nouveaux handlers d'administration
- `app/lib/screens/settings/`
- `app/lib/screens/player/widgets/player_info_sheet.dart`

### Terminé quand

- Un administrateur peut expliquer depuis une seule vue pourquoi une session transcode ou bufferise.
- Les données de diagnostic ne contiennent ni mot de passe, ni token, ni chemin complet sensible par défaut.

---

## Chantiers transversaux obligatoires

### Accessibilité et entrées

- Navigation complète au clavier et à la télécommande.
- Focus visible sur chaque action.
- Cibles tactiles d'au moins 44 × 44 px.
- Libellés sémantiques pour les contrôles du lecteur.
- Respect de `MediaQuery.disableAnimations`.

### Résilience

- Timeout borné pour chaque ouverture et changement de session.
- Boutons `Réessayer`, `Passer en qualité automatique` et `Revenir au Direct Play` selon l'erreur.
- Conservation de la position avant toute reconstruction du moteur.
- Destruction garantie des sessions HLS abandonnées.

### Compatibilité et migrations

- Chaque migration de base est transactionnelle et testée depuis une base de la version précédente.
- Les versions client/serveur incompatibles produisent un message clair avant la lecture.
- Les nouvelles capacités sont négociées et facultatives pendant la période de transition.

### Performance

- Aucun rebuild de toute la page sur les ticks de position à haute fréquence.
- Blur et overlays vérifiés sur appareils Android TV modestes.
- Cache borné pour affiches, sous-titres, miniatures et médias hors ligne.

## Ordre de livraison conseillé

### Version 1 — prête pour une exposition distante

- Phase 0.
- Phase 1.
- Première version de la phase 8 : sessions actives et raison du transcodage.

### Version 2 — lecture adaptative

- Phase 2.
- Préférences audio/sous-titres de la phase 6.

### Version 3 — expérience multi-appareils et foyer

- Phase 3.
- Phase 4.

### Version 4 — mobilité premium

- Phase 5.
- Miniatures de seek de la phase 6.

### Version 5 — catalogue mature

- Phase 7.
- Phase 8 complète.

## Définition globale de « comparable à Plex/Emby »

La feuille de route est accomplie lorsque les conditions suivantes sont toutes vraies :

- Une vidéo personnelle n'est jamais accessible sans autorisation temporaire.
- Sur réseau variable, la lecture s'adapte sans intervention et sans boucle de buffering.
- Le chemin Direct Play/remux/transcode et sa raison sont toujours explicables.
- Une lecture peut être lancée et pilotée sur une TV depuis un téléphone.
- Les profils d'un foyer ont des progressions, préférences et restrictions indépendantes.
- Les téléchargements reprennent après redémarrage et se lisent entièrement hors ligne.
- Le scrubber fournit un aperçu visuel et reste fluide sur chaque chrome.
- Audio, sous-titres, fréquence d'affichage, HDR et reprise sont couverts par une matrice de tests.
- Un administrateur peut diagnostiquer une session sans accéder aux secrets de l'utilisateur.

## Hors périmètre volontaire

- Live TV, guide des programmes et DVR.
- Bibliothèques musicales et photographiques.
- Watch Together synchronisé entre plusieurs foyers.
- Clients Roku, Tizen, webOS, consoles et Apple TV natif.
- Recommandations éditoriales ou service de streaming public.

Ces sujets pourront devenir des feuilles de route séparées une fois les phases P0 et P1 stabilisées. Watch Together est notamment moins prioritaire qu'auparavant : Plex en a réduit la disponibilité sur ses nouvelles applications en 2025.
