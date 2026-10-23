# ADR-0081 — TheIntroDB passe en v4 et le choix des repères se resserre

- **Statut :** accepté. Testé en Go (`server/indexer/introdb_test.go`) ; l'API v4 interrogée à la
  main (200 et 404), pas encore vue sur une vraie médiathèque.
- **Date :** 2026-10-23
- **Portée :** `server/indexer/introdb.go`, `analyzeSeason` et `DetectFromChapters`
  (`server/indexer/detection.go`).

## Contexte

Le serveur interrogeait `api.introdb.app/segments`, l'ancienne adresse. Elle répond encore, mais
sa base n'est plus alimentée : pour Breaking Bad S01E01 elle n'a ni intro, ni récap, alors que
l'API actuelle (`api.theintrodb.org/v4/media`) a une intro et des crédits. Sur les séries où
l'ancienne base est vide, le saut d'intro ne tenait que par les chapitres du fichier.

La doc de TheIntroDB confirme que **la lecture ne demande pas de clé** (`GET /media`, 5 000
appels par jour par adresse IP, rafale de 30 par 10 s) ; la clé ne sert qu'à soumettre.

Le choix des repères avait aussi trois défauts :
- un récap en pré-générique (0-60 s) et une intro à 5 minutes étaient fusionnés en une fenêtre
  0-300 s : le client sautait 5 minutes d'épisode ;
- les chapitres du fichier, passés après TheIntroDB, réécrivaient les quatre repères : un
  fichier dont les chapitres ne nomment que l'intro effaçait le générique de TheIntroDB, et
  surtout TheIntroDB l'emportait sur les chapitres, plus fiables car propres au fichier ;
- un début d'intro à 0 (intro dès la première seconde) comptait comme « pas d'intro » dans le
  test qui décide d'interroger les chapitres.

## Décision

1. **API v4, lue par `tmdb_id`** de la série (la numérotation de la médiathèque est celle de
   TMDB), à défaut par l'`imdb_id` déjà connu. Plus d'appel TMDB pour convertir l'identifiant.
2. **La durée du fichier part en `duration_ms`** (dans la plage 5 min - 6 h que l'API accepte) :
   c'est ce qui lui permet de reconnaître la version dont viennent les horodatages.
3. **Les réponses sont des listes** (`intro`, `recap`, `credits`, `preview`), à bornes
   facultatives : un début absent vaut 0, une fin absente d'un générique vaut la fin du fichier.
4. **Intro** : la plus précoce des vraisemblables, une valeur aberrante laissant la place à une
   bonne. **Récap** : fusionné à l'intro seulement s'il la précède à moins de 30 s ; sinon l'intro
   reste seule. **Générique** : le plus précoce qui tombe dans la seconde moitié de l'épisode —
   là où l'épisode suivant se propose ; la scène post-générique ne le repousse pas.
5. **Les chapitres du fichier d'abord, TheIntroDB pour compléter.** Un chapitre décrit ce
   fichier précis ; TheIntroDB, des horodatages de la communauté pour une version qui peut
   différer. Le serveur lit donc les chapitres en premier, puis n'interroge TheIntroDB que pour
   les épisodes à qui il manque l'intro ou le générique, et n'y prend que ce qui manque
   (`FillMissingMarkers`) : un fichier dont les chapitres ne nomment que le générique garde
   l'intro de TheIntroDB. L'app suit le même ordre (intro et générique : chapitre nommé, puis
   base). Effet de bord utile : un épisode entièrement décrit par ses chapitres ne coûte aucun
   appel à TheIntroDB. En contrepartie, chaque épisode en attente passe par un ffprobe.
6. **Un 429 arrête la saison** (`ErrIntroDBThrottled`) : le client de `httpx` a déjà rejoué le
   refus, insister ferait échouer le reste pareil. Les épisodes restants ne sont pas marqués
   vérifiés et seront repris à la prochaine passe.

## Conséquences

- Le serveur envoie les requêtes de lecture depuis une seule adresse : 5 000 appels par jour
  suffisent pour environ 200 saisons, et le cooldown de 30 minutes par saison
  (`seasonAnalysisCooldown`) et la fenêtre de 30 jours (`introPendingCondition`) les bornent.
- Les films ne sont toujours pas couverts (pas de saut de générique) : la base les connaît, le
  schéma et l'app ne portent les repères que pour les épisodes.
- Le récap n'a toujours pas de colonne à lui : seul l'ADR-0064 (chapitres) le propose à part.
- Les épisodes déjà analysés ne sont pas réinterrogés avant la fin de leur fenêtre de 30 jours ;
  la détection explicite d'une série (`DetectIntrosOutrosForShow`) force la nouvelle lecture.
