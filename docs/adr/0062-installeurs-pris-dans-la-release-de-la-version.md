# ADR-0062 — Les installeurs ne sont plus dans l'image : le serveur les prend dans la Release de sa version

- **Statut :** accepté. Le Go est testé (`server/releasedl`, `server/handlers/downloads_release_test.go`).
  **Rien n'a encore tourné contre l'API réelle de GitHub ni dans une image publiée.**
- **Date :** 2026-10-13
- **Portée :** `server/releasedl`, `server/handlers/downloads.go` et `downloads_release.go`,
  `server/main.go`, `server/Dockerfile`, `.github/workflows/release.yml` et `server.yml`,
  `publish-image.sh` / `.ps1`.
- **Prolonge** l'[ADR-0042](0042-adresse-du-serveur-deduite-de-l-installeur.md) : le serveur
  annote toujours l'APK et l'IPA au vol ; seul l'endroit d'où vient le fichier change.

## Contexte

L'image du serveur pesait 437 Mo compressés (1,23 Go sur disque). Les installeurs (APK, DMG, EXE,
ZIP, IPA) en faisaient 358 Mo décompressés, plus du tiers, et chaque `docker pull` les
téléchargeait même sur un serveur dont personne n'installe l'app.

Ils sont déjà joints à la GitHub Release (dépôt public) par `release.yml`.

## Décision

**L'image n'embarque aucun installeur. Le serveur propose ceux de la Release qui porte sa propre
version, et seulement celle-là.**

1. **Une version, une Release.** `release.yml` passe `--build-arg VERSION=<version>` (il ne le
   faisait pas : une image publiée annonçait `dev`). Le serveur demande `releases/tags/v<version>`.
   Un serveur en 1.2.0 n'est donc ni « en retard » sur la 1.3.0 ni « en avance » sur la 1.1.0 : une
   app installée depuis lui est de sa version, et `UpdateChecker` ne lui voit une mise à jour que
   quand le serveur est lui-même mis à jour.
2. **Sans Release exacte, la plus récente.** Une version qui n'est pas `X.Y.Z` (`dev`,
   `main-<sha>` des images de `server.yml`) n'a pas de Release : le serveur prend `releases/latest`.
   Une version `X.Y.Z` sans Release n'emprunte pas celle d'une autre : la liste est vide.
3. **Téléchargement paresseux, cache disque.** La liste est tenue 15 minutes en mémoire et écrite
   dans `release-cache/` (à côté de la base). Elle est lue en fond dès le démarrage, et une liste
   connue (mémoire ou disque) se sert toujours tout de suite : périmée, elle est rafraîchie
   derrière, sans faire attendre la requête (2026-10-16 : chaque fin de TTL et chaque redémarrage
   faisaient attendre GitHub jusqu'à 10 s avant la recherche de mise à jour). Un installeur est téléchargé à la première requête
   `GET` puis resservi depuis le disque, avec l'annotation de l'ADR-0042 et les `Range`. Un `HEAD`
   ne déclenche pas le téléchargement. À la mise à jour du serveur, les dossiers des versions
   précédentes sont supprimés.
4. **Hors ligne.** Si GitHub ne répond pas, le serveur ressert la dernière liste connue (mémoire,
   puis disque) et réessaie dans une minute. Sans liste jamais vue, la section « Applications »
   disparaît, comme avant. `RELEASE_REPO=off` coupe la source.
5. **Le dossier posé à la main reste prioritaire.** `DOWNLOADS_DIR` (envoi par l'administrateur,
   volume) l'emporte sur la Release pour sa plateforme : c'est un choix délibéré. Les routes
   d'envoi et de suppression ne portent que sur ce dossier.

## Conséquences

- L'image perd environ 358 Mo décompressés. `mesa-vulkan-swrast` (240 Mo, ADR-0060) reste.
- Le premier utilisateur qui télécharge un installeur sur un serveur attend le transfert depuis
  GitHub (une centaine de Mo) avant que ses premiers octets arrivent. Les suivants non.
- Un serveur a besoin d'Internet (GitHub) au moins une fois par version pour proposer les
  installeurs. L'ancienne image les portait sans réseau.
- L'API non authentifiée de GitHub limite à 60 requêtes par heure et par adresse ; le cache de 15
  minutes et le cache disque en consomment peu.
- Une image publiée à la main (`publish-image.sh`) sans passer par `release.yml` n'a pas de
  Release : elle n'a rien à proposer tant que `v<version>` n'existe pas.
- `server.yml` ne reprend plus les installateurs de l'image `:latest`.

## Alternatives écartées

- **Un volume `downloads` rempli à part** : à charge de chaque administrateur, et rien ne garantit
  que la version des fichiers suive celle du serveur.
- **Rediriger vers l'URL de la Release (302)** : l'annotation de l'ADR-0042 (l'APK qui s'ouvre sur
  ce serveur) serait perdue, puisque le fichier ne passerait plus par lui.
- **Deux images, avec et sans installeurs** : deux tags à tenir, et le plus gros poste resterait
  téléchargé par quiconque prend la bonne.
