# Banc de qualité de lecture

Phase 0 de [la roadmap](roadmap-lecture.md). Les attentes ci-dessous sont des contrats à vérifier, pas des validations matérielles déjà effectuées.

## Corpus

Conserver des extraits autorisés d'au moins 60 secondes, avec mouvement, paroles et repère de synchronisation audio/vidéo. Ne pas committer les médias. Identifier chaque extrait par SHA-256, durée, codec, profil, débit, pistes et métadonnées HDR obtenus par ffprobe. Une simple balise HDR ajoutée à une mire SDR ne valide pas le HDR. Dolby Vision et Atmos exigent de vrais flux avec leurs métadonnées.

| Identifiant | Vidéo | Audio | Sous-titres |
| --- | --- | --- | --- |
| h264-sdr | H.264 1080p 8 bits SDR | AAC stéréo, français/anglais | SRT externe, ASS interne |
| hevc-hdr10 | HEVC 2160p 10 bits PQ/BT.2020 | AC-3 5.1 | PGS interne |
| dv5 | HEVC Dolby Vision profil 5 | E-AC-3 JOC/Atmos | SRT |
| dv8 | HEVC Dolby Vision profil 8.1, base HDR10 | TrueHD/Atmos 7.1 | PGS |
| av1-sdr | AV1 1080p SDR | DTS 5.1 et AAC stéréo | ASS |

Ajouter un film long (deux heures) pour les seeks éloignés, un épisode avec intro/outro et un épisode suivant. Les identifiants de catalogue réels restent dans les notes locales de validation.

## Chemins attendus

Direct Play : fichier source lu directement. Remux : vidéo copiée vers HLS, avec audio copié ou réencodé selon `PlanAudio`. Transcodage : vidéo réencodée, avec tone mapping si HDR. Les tests `TestRoadmapPlaybackMatrix` portent sur les décisions HLS ; ils ne prouvent pas que le moteur natif rend correctement le fichier.

| Plateforme | H.264 SDR | HEVC HDR10 | DV5 | DV8.1 | AV1 SDR |
| --- | --- | --- | --- | --- | --- |
| macOS arm64, mpv natif gpu-next | Direct | Direct, HDR ou tone mapping GPU | Direct avec RPU | Direct | Direct |
| macOS x86_64, mpv texture | Direct | Direct, traitement mpv | Transcodage SDR | Direct, base HDR10 | Direct, débit à mesurer |
| Windows, mpv texture | Direct | Direct, traitement mpv | Transcodage SDR | Direct, base HDR10 | Direct |
| iOS, mpv texture | Direct | Direct, traitement mpv | Transcodage SDR | Direct, base HDR10 | Direct, débit à mesurer |
| Android mobile | Direct si décodeur déclaré | Direct si HEVC/HDR déclarés, sinon SDR | Direct seulement avec décodeur DV, sinon SDR | Base HDR10 si compatible, sinon SDR | Direct si AV1 déclaré, sinon H.264 |
| Android TV | Même règle, relever décodeur et sortie HDMI | Même règle | Même règle | Même règle | Même règle |
| Web | Direct si conteneur accepté, sinon remux | Selon capacités MSE ; SDR avec déclaration 8 bits | Transcodage SDR | Transcodage SDR avec déclaration 8 bits | Direct/remux si MSE accepte, sinon H.264 |

La déclaration effective prime sur le nom de la plateforme. Sur macOS x86_64, un moteur natif gpu-next réellement actif suit la ligne native. En qualité manuelle inférieure à la source, au-dessus du plafond de débit ou avec PGS brûlé, attendre un transcodage. SRT/ASS ne doivent pas imposer un transcodage lorsqu'ils sont rendus par le client.

AAC/AC-3/E-AC-3 doivent être copiés en HLS si le client déclare le codec et assez de canaux. TrueHD et DTS passent directement dans mpv, mais sont convertis en HLS ; ne pas confondre conservation des canaux et conservation des objets Atmos. Sur Android, vérifier le décodeur logiciel et le passthrough sur la sortie réelle. Le navigateur conservateur reçoit AAC stéréo.

## Exécution automatique locale

Depuis la racine : `bash scripts/validate-playback.sh`. Le script lance les suites Go et Flutter et échoue si l'une échoue. Il n'appelle aucun serveur externe. Les intégrations FFmpeg sont omises explicitement sans corpus.

Pour exercer FFmpeg, fournir un extrait local contenant une vidéo prise en charge et une première piste AAC/AC-3/E-AC-3 : `ONYX_IT_MEDIA=/chemin/extrait.mkv bash scripts/validate-playback.sh`. Les tests existants vérifient les segments réellement produits avec ffprobe. Le corpus DV/HDR complet exige les validations matérielles ci-dessous.

Un premier extrait H.264 SDR avec E-AC-3 5.1 et AAC stéréo se génère avec `bash scripts/generate-playback-fixture.sh /tmp/onyx-quality-fixture.mkv`. La première piste est silencieuse : ce fichier valide conteneurs, canaux et encodage, pas l'écoute surround ni la synchronisation A/V. Le script refuse d'écraser un fichier existant.

Couverture existante à conserver : `master_playlist_test.go`, `handler_files_test.go`, `ffmpeg_test.go`, `integration_test.go`, `roadmap_matrix_test.go` ; côté Flutter, `playback_session_lifecycle_test.dart`, `web_quality_test.dart`, `progress_sync_test.dart`, `onyx_controls_layer_test.dart`, `onyx_settings_menu_tv_test.dart`, `seek_feedback_overlay_test.dart` et les tests de focus et de téléchargements.

## Procédure sur appareils réels

Créer une copie du relevé ci-dessous par appareil, moteur, chrome (standard, Chrome Onyx, Studio) et extrait. Répéter trois fois à froid puis à chaud. Garder le même écran, sortie audio et réseau entre deux versions comparées.

1. Ouvrir la fiche et lancer la lecture. Mesurer jusqu'à la première image visible, pas seulement jusqu'à l'état « playing ».
2. Relever le chemin, la raison du transcodage, les codecs, le débit et les compteurs d'images perdues au départ puis après 60 secondes.
3. Seek de +10 secondes, puis à 75 % de la durée. Mesurer délai de nouvelle image et écart à la position demandée.
4. Changer audio et sous-titres, puis qualité. Vérifier langue, sélection, son, image et position (écart maximal de deux secondes pour la qualité).
5. Couper uniquement le réseau de l'appareil de test pendant 15 secondes, rétablir, mesurer la reprise et vérifier qu'un échec offre une récupération.
6. Fermer le lecteur, rouvrir le média puis reprendre sur un autre appareil du même utilisateur. Vérifier position et absence de session HLS orpheline.
7. Vérifier PiP Android : entrée, pause/reprise, retour, fermeture ; ni second audio ni session survivante.
8. Sur TV, vérifier fréquence 23,976/24/25/50/60 Hz, restauration après sortie, play/pause/seek/retour et focus visible de chaque menu à la télécommande.
9. Sur écran HDR, contrôler signal de sortie et couleurs avec les extraits connus ; sur sortie SDR, vérifier le tone mapping. Mesurer le décalage A/V avec le repère du corpus.
10. Télécharger puis passer hors ligne : vérifier pistes, sous-titres, marqueurs et progression après reconnexion.

## Relevé à remplir

Date / opérateur : non exécuté. Commit client / serveur : à renseigner. Appareil / OS / moteur / écran / sortie audio / chrome : à renseigner.

| Extrait SHA-256 | Réseau | Chemin et raison | Première image ms | Seek court/long ms | Écart position s | Buffer s | Images perdues (delta) | Décalage A/V ms | Reprise réseau ms | Résultat |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| À renseigner | | | | | | | | | | Non exécuté |

Une mesure absente reste « non mesurée », jamais zéro. Aucun relevé partagé ne contient d'URL signée, token, mot de passe ou chemin de bibliothèque personnel. Toute installation, configuration ou ajout de corpus sur le serveur externe demande l'accord de son propriétaire.

## Exécution du 12 septembre 2026

- Suites Go locales : succès, y compris les deux intégrations FFmpeg avec l'extrait synthétique H.264 / E-AC-3 / AAC.
- Matrice des décisions de lecture : 50 sous-tests, succès.
- Suite Flutter : 312 tests, succès.
- Build et lancement macOS debug : succès ; le moteur annonce mpv natif gpu-next, HDR et Dolby Vision.
- Validation visuelle de l'app : en attente. L'arbre d'accessibilité ne retourne que la fenêtre ; la capture native échoue avec ScreenCaptureKit `-3811`. Aucune lecture réelle ni connexion au serveur n'est certifiée par ces observations.
- Validation HDR, Atmos, iOS, Windows et Android : non exécutée.

Ces résultats constituent le début de la phase 0. Les critères complets de la phase 0 et les phases 1 à 8 restent à réaliser ; aucun déploiement ni changement du serveur externe n'a été effectué.
