# ADR-0070 — Les listes : « À regarder plus tard » et des listes à soi, partagées ou non

- **Statut :** accepté
- **Date :** 2026-10-19
- **Portée :** le serveur (`server/watchlists/`, `server/handlers/watch_lists.go`,
  `server/models/watch_list.go`, migration 28, capacité `watch_lists` dans
  `server/handlers/ping.go`, `contract/watch_list*.json`) et l'app
  (`app/lib/models/watch_list.dart`, `app/lib/services/api/watch_lists.dart`,
  `app/lib/providers/watch_lists_provider.dart`, `app/lib/screens/lists/`,
  `app/lib/widgets/global/add_to_list_button.dart`).

## Contexte

On voulait garder de côté ce qu'on regardera plus tard, et composer des listes —
« Mes recommandations », « Films de Noël » — que les autres comptes du serveur
peuvent voir, ou non. Une liste « à regarder plus tard » doit aussi pouvoir
retenir un titre que le serveur n'a pas encore : celui qu'on croise dans le
catalogue des demandes.

## Décision

1. **Deux sortes de listes.** Chaque compte a une liste `watch_later`, créée par
   le serveur à la première lecture de ses listes : elle ne se renomme ni ne se
   supprime, et l'app l'affiche sous son nom traduit. Les autres (`custom`) sont
   libres : nom, description, partage.
2. **Partager, c'est la montrer à tous les comptes du serveur, en lecture
   seule.** `is_shared` est un interrupteur, pas une liste de destinataires :
   le serveur n'a pas de bibliothèques par compte, et « les autres » sont ceux
   qui ont un compte ici. Seul le propriétaire modifie. Une liste privée lue par
   un autre compte répond 404 : son existence ne se devine pas.
3. **Un élément est un film ou une série, identifié d'abord par TMDB.** Il garde
   `media_type` et `tmdb_id` quand on les connaît, et `media_id` quand il a été
   ajouté depuis le serveur. Un titre ajouté depuis le catalogue n'a que son
   identité TMDB : le jour où il arrive sur le serveur, la lecture le rattache à
   la fiche qui porte le même `tmdb_id` et il devient lisible, sans rien
   réécrire. Un film en plusieurs versions se rattache à la plus ancienne ligne.
4. **Un instantané pour ce qui n'est pas (ou plus) sur le serveur.** Titre,
   affiche et date sont copiés à l'ajout ; une fiche rattachée les remplace par
   les siens, traduits (ADR-0049). Depuis le catalogue, l'app n'envoie qu'un
   chemin d'affiche TMDB (`/abc.jpg`), que le serveur vérifie et complète : une
   liste partagée ne peut pas faire charger aux autres une adresse quelconque.
5. **Ajouter deux fois ne double pas.** Un même titre, par `media_id` ou par
   `tmdb_id`, n'est qu'une fois dans une liste : l'ajout renvoie l'élément
   existant. Des index uniques partiels le garantissent en base.
6. **Bornes.** 200 listes par compte, 1 000 éléments par liste, nom de 80
   caractères, description de 500 : une liste partagée se lit par tous, elle ne
   doit pas devenir un dépôt.
7. **`GET /api/lists?media_id=` ou `?tmdb_id=&media_type=`** dit, pour chacune de
   mes listes, l'élément qui contient ce titre : la feuille « Ajouter à une
   liste » coche et décoche en un seul appel de lecture.
8. **La capacité `watch_lists`** sur `/api/ping` : l'app ne montre ni l'onglet
   ni le bouton à un serveur plus ancien (ADR-0051).

## Alternatives écartées

- **Partager avec des comptes choisis.** Rien ne le demande encore, et une
  table de destinataires se rajoute sans toucher aux listes existantes.
- **Le « plus tard » sur l'appareil.** Il ne suivrait pas le compte d'un
  téléphone à la télévision, et c'est au serveur de tenir l'état du compte.
- **Demander à TMDB les détails à l'ajout.** Le serveur dépendrait d'un appel
  sortant pour une écriture locale ; l'instantané envoyé suffit, la fiche du
  serveur le remplace dès qu'elle existe.
- **Les épisodes et saisons.** Une liste nomme ce qu'on veut regarder ; la série
  y mène, et « Reprendre » sait déjà à quel épisode on en est.

## Conséquences

- Une fiche supprimée du serveur laisse son élément dans la liste, sous son
  instantané : il redevient lisible si elle revient avec le même `tmdb_id`.
- Une fiche sans identité TMDB, ré-identifiée plus tard, reste rattachée par
  `media_id`.
- Supprimer un compte supprime ses listes (clé étrangère), partagées comprises.
- Avec plusieurs serveurs (ADR-0013), les listes sont celles du serveur actif.
