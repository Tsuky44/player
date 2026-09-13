# ADR-0016 — Les aperçus de la barre de lecture, une image clé à la fois

- **Statut :** accepté, réalisé — vérification dans l'app encore à faire
- **Date :** 2026-09-14
- **Portée :** le chrome Emby (ordinateur, téléphone, téléviseur). Pas les dispositions modulaires
  ni le HUD par défaut.

## Contexte

Survoler la barre de lecture n'affichait qu'un temps. On veut l'image de ce moment-là, en grand,
sans ralentir le démarrage de la lecture et sans attendre dix secondes qu'elle apparaisse.

La forme habituelle — une planche de vignettes générée en une passe (trickplay de Jellyfin) — lit
et décode tout le fichier avant de pouvoir répondre au premier survol : plusieurs minutes pour un
remux 4K sur la machine de production, qui n'a pas de GPU.

## Décision

### 1. Une image = une image clé, extraite à la demande

`ffmpeg -skip_frame nokey -ss T -noaccurate_seek -i … -frames:v 1` saute à l'image clé qui précède
`T` et ne décode qu'elle. Mesuré : ~40 ms pour du H.264 1080p, ~170 ms pour du HEVC 4K 10 bits, sur
un cœur. C'est assez rapide pour répondre au survol lui-même. L'image est réduite à 480 px de large
avant la conversion HDR → SDR, comme sur le chemin de transcodage.

L'écart entre deux images est choisi pour en avoir ~600 par fichier, borné entre 4 et 20 s.

### 2. Deux producteurs, un cache disque

- **Le survol** : `GET /api/v1/media/:id/previews/:i.jpg` sert l'image si elle existe, l'extrait
  sinon (au plus deux extractions de ce type à la fois, une seule par image même si plusieurs la
  demandent).
- **La passe de fond** : démarrée par `POST /api/v1/media/:id/previews`, **que le client n'appelle
  qu'après la première image affichée**. Elle remplit la barre du grossier au fin (une image sur
  2ⁿ, puis les moitiés), sur un cœur, en priorité basse (`nice`), et s'arrête dès que le ticket de
  lecture qui l'a demandée n'est plus valide. Deux passes au plus en même temps.

Le cache vit dans `data/previews` (`PREVIEW_DIR`), un dossier par fichier dont le nom dépend de sa
taille et de sa date : un fichier remplacé ne ressert jamais les images de l'ancien. Au-delà de
`PREVIEW_CACHE_MB` (2 Go par défaut), les dossiers les moins récemment utilisés sont supprimés.

### 3. Côté client : toujours la dernière position

Une seule requête à la fois, toujours pour la dernière position survolée — un balayage rapide ne met
pas en file toutes les images traversées. Pendant qu'elle charge, l'image la plus proche déjà en
mémoire tient la place ; une fois le pointeur posé, les voisines sont chargées aussi. Au bout de
quatre échecs d'affilée, la barre revient à la simple bulle de temps.

Sur téléviseur, l'aperçu suit la cible d'une avance/recul à la télécommande tant qu'elle n'est pas
validée.

## Conséquences

- Un média téléchargé, lu hors ligne, n'a pas d'aperçus : il n'y a pas de serveur pour les produire.
- L'image montrée est l'image clé *avant* la position ; sur un encodage à GOP très long, elle peut
  précéder le pointeur de quelques secondes.
- Un Dolby Vision profil 5 garde les couleurs fausses du tone mapping zscale, comme en transcodage.
