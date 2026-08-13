# ADR-0001 — Droits utilisateur et invitations

- **Statut :** accepté
- **Date :** 2026-08-13
- **Portée :** lot (A), droits d'administration. Le lot (B) — accès au contenu — est explicitement hors périmètre.

## Contexte

Avant ce changement, `users` ne contenait que `id`, `username`, `password_hash`. Il n'existait
aucune notion de rôle ni d'administrateur. Conséquences concrètes :

- `POST /api/auth/register` était ouvert : n'importe qui pouvait se créer un compte.
- Tout compte authentifié pouvait réécrire les clés TMDB / MediaHub et repointer les dossiers
  de la bibliothèque via `PUT /api/settings`.
- `POST /api/indexer/debug/delete-show` — la route la plus destructrice du serveur — n'exigeait
  aucune authentification.

Le besoin exprimé : accorder des droits différents à des utilisateurs différents, à la manière
d'Emby.

## Décision

### Découpage en deux lots

Le lot (A) couvre l'**administration du serveur** : qui peut modifier les réglages, indexer,
supprimer, gérer les comptes, inviter. Le lot (B), séparé, couvrira l'**accès au contenu** :
bibliothèques visibles, contrôle parental, téléchargements, et la fermeture de `/stream`.

Raison du découpage : (B) suppose une notion de « bibliothèque » qui n'existe pas encore — les
médias forment un arbre plat — et impose de filtrer une quinzaine d'endpoints de lecture plus de
signer les URLs de `/stream`, aujourd'hui volontairement publique pour la compatibilité des
players externes. Mélanger les deux garantissait un chantier à moitié fini.

**Conséquence assumée : à la fin de (A), `/stream` reste accessible sans authentification pour
qui connaît l'URL.** (A) protège l'administration, pas l'accès au contenu.

### Six permissions, pas de rôles

`manage_settings`, `manage_library`, `manage_users`, `delete_media`, `invite_users`,
`request_media`. Stockées en colonnes booléennes sur `users` plutôt qu'en table de jointure : le
jeu est fixe, et le middleware les lit à chaque requête — pas de jointure sur ce chemin chaud.

« Administrateur » n'est pas un rôle stocké : c'est un raccourci d'UI qui coche les six cases.

`manage_settings` et `manage_library` restent séparés bien que proches : lancer un scan est
bénin et délégable, réécrire une clé API ou repointer `MoviesDir` ne l'est pas.

`request_media` est le seul flag positif — activé par défaut à la création d'un compte.

### Le propriétaire est asymétrique

Le premier compte créé porte `is_owner`. Le propriétaire peut retirer ses droits à n'importe quel
administrateur ; personne ne peut retirer les siens, ni réinitialiser son mot de passe, ni
supprimer son compte. Il peut **transférer** son statut à un autre administrateur (un seul
propriétaire à la fois).

Pourquoi l'asymétrie plutôt qu'une relation symétrique entre admins : sur un serveur familial, la
personne que l'on promeut est de confiance jusqu'au jour où elle clique de travers. En symétrique,
quiconque est promu peut verrouiller le propriétaire hors de son propre serveur, sans aucun
recours applicatif — retour au `UPDATE` manuel en SQLite. Le coût de l'asymétrie est une colonne
posée une fois.

En dessous de cette règle, un filet : le serveur refuse toute opération qui ferait tomber le
nombre de comptes portant `manage_users` à zéro.

### L'inscription passe par invitation

`POST /api/auth/register` n'aboutit que dans deux cas :

1. La table `users` est vide — ce compte devient le propriétaire. Sans cette porte, une
   installation neuve serait inadministrable, puisque inviter suppose un compte.
2. Un token d'invitation valide est fourni.

`GET /api/auth/state` expose un unique booléen `setup_required` pour que l'écran de connexion
sache s'il doit proposer le formulaire d'inscription.

### L'inviteur ne choisit pas les droits qu'il accorde

C'est la décision la moins évidente du lot. `invite_users` peut être accordé à un non-administrateur
— pour qu'un proche fasse entrer un ami sans passer par le propriétaire. Si cet inviteur pouvait
cocher les droits de ses liens, il générerait un lien `manage_users`, l'utiliserait lui-même, et
se fabriquerait un compte administrateur : **le droit d'inviter deviendrait le droit de tout faire**.

Le droit d'inviter est donc un booléen **plus un gabarit** (`invite_grants`) : c'est
l'administrateur qui coche, au moment où il accorde `invite_users`, ce que les liens de cette
personne accorderont. L'inviteur ne fait que cliquer « générer un lien ». L'UI interdit en outre
`manage_users` dans un gabarit.

Un administrateur (`manage_users`) peut, lui, choisir librement les droits de ses propres liens :
il peut déjà promouvoir n'importe qui après coup, cela n'ouvre rien de neuf.

### Cycle de vie d'un lien

Usage unique, 7 jours en dur, révocable. Les droits sont **figés à la création** : un lien fait
exactement ce qu'il annonçait, même si le gabarit de son émetteur change ensuite.

Retirer `invite_users` à quelqu'un **révoque en cascade ses liens en attente** — sinon retirer le
droit ne veut rien dire tant que des liens circulent. Modifier son gabarit ne révoque rien : cela
tuerait sans prévenir une invitation légitime en cours, et n'affecte donc que les liens futurs.

L'expiration est dérivée à la lecture, pas balayée par un job.

### Le lien est fabriqué par le client

Le serveur ne connaît pas son URL publique : il écoute sur `:8080` derrière un proxy, un domaine
ou un tunnel. Le client compose donc le lien à partir de l'adresse qu'il utilise lui-même, ce qui
donne par construction une URL qui fonctionne pour l'inviteur. Elle peut être purement locale,
d'où l'affichage systématique du **code brut à côté du lien** — c'est de toute façon le seul
chemin praticable sur les apps natives, qui n'ont pas de deep-link.

Un réglage « URL publique » a été écarté : renseigné une fois, oublié, puis faux le jour où le
domaine change, avec des liens cassés sans message d'erreur.

### Le masquage d'UI n'est pas une sécurité

Les sections de paramètres interdites sont absentes de l'arbre de widgets, pas grisées — ce qui
n'est pas affiché ne peut pas produire de 403, et personne n'a besoin de savoir qu'un réglage TMDB
existe. La garde réelle reste `RequirePermission` côté Go : un `curl` ou un client modifié ne gagne
rien.

## Conséquences

- Migration : sur une base existante, `MIN(id)` devient propriétaire avec tous les droits, les
  autres comptes reçoivent `request_media`. Idempotent, gardé par `NOT EXISTS (… is_owner = 1)`
  pour ne jamais défaire un transfert de propriété.
- `delete-show` exige désormais `delete_media`.
- `GET /api/settings` exige `manage_settings` : le snapshot expose `MoviesDir` / `SeriesDir`.
- `/api/downloads` **reste public** : il distribue les installeurs aux gens qui n'ont pas encore
  l'app — dont les invités, qui doivent l'installer avant de pouvoir avoir un compte. Le fermer
  créerait un blocage circulaire.
- La suppression d'un compte est dure et en cascade (progressions, layouts, sessions,
  invitations). Ni corbeille, ni désactivation : sur un serveur familial, on supprime un compte
  deux fois dans sa vie, et des lignes mortes compliqueraient chaque requête.
- Une réinitialisation de mot de passe par un administrateur ferme toutes les sessions du compte
  visé ; un changement de mot de passe par l'intéressé ne ferme rien (rotation, pas récupération).
- L'écran de connexion doit être recompilé pour le build web (`server/webui/dist`) pour que
  l'inscription par lien fonctionne dans le navigateur.
