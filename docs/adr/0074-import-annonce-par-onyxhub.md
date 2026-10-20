# ADR-0074 — Un import annoncé par OnyxHub s'indexe sans attendre le moniteur

- **Statut :** accepté
- **Date :** 2026-10-20
- **Portée :** le serveur (`server/indexer/monitor_nudge.go`, `server/handlers/onyxhub_import.go`,
  la route `POST /api/integrations/onyxhub/imported` dans `server/main.go`, capacité
  `onyxhub_import_signal` dans `server/handlers/ping.go`). Côté OnyxHub : son ADR-0011.

## Contexte

Le moniteur (ADR-0018) voit un nouveau fichier par les notifications du système de fichiers,
aveugles sur un partage réseau, ou par le poll des dossiers, toutes les 5 minutes par défaut.
Radarr et Sonarr préviennent OnyxHub dès qu'ils ont rangé un fichier : l'information existait,
elle n'arrivait pas jusqu'à Onyx.

## Décision

- `POST /api/integrations/onyxhub/imported`, sans compte. OnyxHub y présente la clé
  d'intégration, celle qu'Onyx lui présente dans l'autre sens, comparée en temps constant.
  Un Onyx sans clé enregistrée refuse tout. La route est limitée comme un sondage.
- Corps `{ tmdbId, mediaType, paths[] }` (100 chemins au plus). Le statut en cache du titre
  est oublié, et `indexer.NudgeLibraryMonitor` fait le reste :
  - un chemin qui tombe dans une bibliothèque fait parcourir son dossier en profondeur,
    15 s plus tard, le temps que Radarr/Sonarr finissent de déplacer le fichier ;
  - dans tous les cas, un passage du poll est avancé, au plus un toutes les 30 s, parce
    qu'une saison importée d'un coup envoie un webhook par épisode.
- Le moniteur ne change pas : le signal avance seulement le moment où il regarde.
  `monitor.go`, au-delà des 800 lignes, ne grossit pas : le code vit dans `monitor_nudge.go`.

## Conséquences

- Quand Onyx et Radarr/Sonarr voient les mêmes chemins (montages identiques), le fichier est
  indexé en quelques secondes. Sinon, le poll anticipé le trouve, sans traduction de chemins
  à configurer.
- Sans le signal (OnyxHub ancien, MediaHub), rien ne change.
