# ADR-0049 — Les fiches suivent la langue de l'interface

- **Statut :** accepté, en cours. Le Go et le Dart sont testés ; **rien n'a été essayé sur une
  vraie bibliothèque** : ni la durée du premier remplissage, ni le rendu des écrans en anglais.
- **Date :** 2026-10-07
- **Portée :** `server/medialang/`, la table `media_translations`, `server/indexer/translations.go`,
  `server/handlers/media_language.go` et les handlers de bibliothèque qui l'appellent,
  `server/indexer/catalog.go`, `server/handlers/tmdb_*.go`, l'en-tête `Accept-Language` posé par
  `app/lib/services/api_client.dart`, le rechargement dans `app/lib/main.dart`.

## Contexte

L'interface existe en français et en anglais (ADR-0047), mais les titres et synopsis restaient
dans une seule langue : celle du réglage « Langue des métadonnées » du serveur, écrite dans la
table `medias` au moment de l'identification. Une app en anglais affichait donc des boutons anglais
autour de fiches françaises.

La langue de l'interface est un choix **par appareil** ; la langue des métadonnées est un réglage
**du serveur**. Deux personnes du même serveur peuvent vouloir deux langues.

## Décision

**L'app annonce sa langue sur chaque requête, et le serveur répond les fiches dans cette langue.**

1. `medias` garde sa langue, dite *de base*. Une table `media_translations` porte le titre et le
   synopsis des fiches dans les autres langues de l'interface — aujourd'hui une seule, l'anglais
   pour un serveur en français. La liste des langues vit dans `medialang.interfaceLocales`.
2. Le remplissage (`translateMissing`) suit l'enrichissement TMDB : au démarrage, après un scan,
   après une ré-identification. Il ne demande que ce qui manque : un appel par film ou série, un
   appel par saison pour tous ses épisodes. Une ligne vide veut dire « TMDB n'a rien ». Elle est
   redemandée au plus une fois par jour pendant les soixante jours qui suivent l'arrivée de la
   fiche — un épisode importé le jour de sa diffusion n'a souvent ni titre ni synopsis traduits —
   puis plus jamais (`translationSettled`).
3. Chaque ligne retient l'identité TMDB dont elle vient (`source_tmdb_id`, celle de la série pour
   un épisode). Une fiche ré-identifiée rend sa traduction caduque sans qu'on ait à l'effacer : elle
   n'est plus servie, et le passage suivant la redemande.
4. L'app envoie `Accept-Language: fr|en`. Le serveur lit `medias` comme avant, puis pose la
   traduction **par-dessus la réponse** (`mediaLanguage.media` / `.items`). Un champ vide laisse le
   texte de base.
5. Ce qui est lu en direct sur TMDB (fiche détaillée, personnes, sagas, saisons manquantes,
   catalogue des demandes) est demandé dans la langue de la requête, et mis en cache par langue.
6. Changer de langue dans l'app vide ce qu'elle a en mémoire et recharge, comme un changement de
   serveur.

Sans en-tête, ou sans aucune langue que l'interface connaît, la réponse est dans la langue de
base : une app d'avant cette décision reçoit exactement ce qu'elle recevait. Quand l'en-tête en
liste plusieurs (un navigateur), la première que l'interface connaît l'emporte.

7. Changer la « Langue des métadonnées » du serveur échange les textes (`medialang.Rebase`) :
   ceux de `medias` deviennent la traduction de l'ancienne langue, et les traductions déjà en
   base dans la nouvelle prennent leur place. Aucun appel à TMDB ; une fiche sans traduction garde
   son texte.

## Alternatives écartées

- **Traduire dans le SQL** (un `LEFT JOIN` dans `mediaColumns`). Le titre de base sert en chemin à
  retrouver un numéro d'épisode et à regrouper les doublons d'une série ; le remplacer dès la
  lecture aurait changé ces résultats selon la langue. Et chaque requête écrite à la main aurait dû
  apprendre la jointure.
- **Demander TMDB à chaque requête**, sans rien stocker. Les listes (accueil, films, séries)
  portent des centaines de fiches : un appel par fiche à chaque ouverture d'écran.
- **Un réglage par compte, côté serveur.** La langue se choisit déjà par appareil (ADR-0047) : un
  téléviseur du salon en français et un téléphone en anglais sur le même compte sont un cas normal.
- **Un en-tête maison** (`X-Onyx-Language`). `Accept-Language` dit exactement cela, et un
  navigateur le laisse passer sans pré-requête.

## Conséquences

- Le premier démarrage après la mise à jour traduit toute la bibliothèque en arrière-plan, à
  environ huit appels TMDB par seconde. D'ici là, une app en anglais voit les fiches pas encore
  traitées en français.
- Les **affiches** ne changent pas avec la langue : une seule est gardée par fiche.
- Restent dans la langue de base : les pages de **liens de partage**, l'**historique** et le
  tableau de bord d'administration (qui gardent le titre du jour de la lecture), les
  **téléchargements** déjà faits, et les noms de dossier des saisons locales. Le « Saison N » que
  le serveur écrit lui-même suit la langue (`medialang.SeasonLabel`).
- L'ordre des listes `GET /api/movies` et `/api/shows` reste celui des titres de base.
- Changer la « Langue des métadonnées » vers une langue hors de l'interface ne retraduit pas
  `medias` (c'était déjà vrai) : il n'y a alors aucune traduction à échanger.
- Ajouter une langue à l'interface demande une ligne dans `medialang.interfaceLocales`, puis un
  passage de remplissage.
