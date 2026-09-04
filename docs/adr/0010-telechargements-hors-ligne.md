# ADR-0010 — Téléchargements hors ligne

- **Statut :** accepté, réalisé
- **Date :** 2026-09-04
- **Portée :** l'app cliente (Android, macOS, Windows) et l'endpoint `POST /api/progress`. Le web
  n'a pas de stockage applicatif et reste inchangé.

## Contexte

Le serveur est chez soi. L'app, elle, part dans un train, dans un avion, dans un métro — et n'y
sert plus à rien : l'authentification au démarrage repose sur `GET /api/auth/me`, chaque écran
tient d'un appel réseau, et la lecture est un `GET /stream` en Direct Play.

Ce que fait Netflix, ce que fait Emby : un bouton qui garde l'épisode sur l'appareil, et une app
qui continue de le lire quand il n'y a plus personne au bout du câble. La difficulté n'est pas le
transfert du fichier — `/stream` est déjà une route publique qui gère les requêtes `Range`. Elle
est dans ce qui vient après : **la progression prise hors ligne doit revenir au serveur sans
écraser ce que d'autres appareils ont fait entre-temps.**

## Décision

### 1. Le fichier d'origine, tel quel

Aucune version « qualité téléchargement ». On rapatrie exactement ce que lit le Direct Play, avec
son extension d'origine — mpv comme ExoPlayer choisissent leur démultiplexeur dessus. Une variante
transcodée aurait demandé au serveur de produire et de stocker un second fichier par média et par
qualité, pour une bibliothèque privée où l'espace disque du serveur est justement la ressource
rare.

Le transfert est un `GET Range:` écrit en append. Une app tuée en plein téléchargement laisse un
fichier partiel parfaitement reprenable : au démarrage suivant l'entrée repasse en file et repart
à l'octet où elle s'était arrêtée.

### 2. Un manifeste JSON, pas une base

`<support applicatif>/onyx_offline/manifest.json` plus un dossier par média. Quelques dizaines
d'entrées, écrites par un seul processus, lues d'un bloc au démarrage : SQLite n'apporterait ici
qu'une dépendance et une migration. L'écriture est atomique (fichier temporaire puis renommage) et
groupée, pour qu'une app tuée pendant la sauvegarde retrouve l'ancien manifeste plutôt qu'un JSON
tronqué.

Le manifeste ne garde **que des noms de fichiers**, jamais des chemins absolus : le conteneur
d'application se déplace d'une version à l'autre, et un chemin gravé ne survivrait pas à une mise
à jour.

### 3. Une session hors ligne, sur un profil mis en cache

`tryAutoLogin` distingue désormais deux échecs. Un 401 est un verdict : la session n'existe plus,
on nettoie. Une absence de réponse n'est un verdict sur rien — l'app ouvre alors une session sur le
profil mis de côté au dernier passage en ligne, avec la même identité et les mêmes droits. Le jeton
n'a pas été invalidé, juste impossible à présenter : la première requête qui aboutira après la
reconnexion repartira normalement.

Cette session-là n'affiche qu'un écran, les téléchargements. Les autres onglets ne sauraient
montrer que des erreurs ; on les retire plutôt que de les laisser échouer, et ils reviennent d'eux-
mêmes dès que `ServerReachability` retrouve le serveur.

### 4. La joignabilité se mesure sur le serveur, pas sur le réseau

`GET /api/ping`, pas un état de connectivité système. Un téléphone peut être parfaitement connecté
au Wi-Fi d'un hôtel sans que le NAS de la maison soit à portée : ce qui compte n'est pas d'avoir du
réseau, c'est d'avoir *ce* serveur. Le sondage est doublé par les erreurs de connexion remontées
par le client HTTP — un appel qui échoue en dit plus long, et plus tôt, que le prochain sondage.

### 5. La progression locale fait autorité tant qu'elle n'a pas été acquittée

Le battement de coeur du lecteur écrit **dans les deux sens** : le serveur d'abord, le manifeste
ensuite, et le manifeste dans tous les cas. Une entrée dont l'envoi a échoué porte `needs_sync`, et
c'est elle qui décide du point de reprise — demander au serveur reviendrait à rembobiner l'épisode
qu'on vient de regarder dans le train.

Au retour de la connexion, chaque entrée en attente est rejouée vers `POST /api/progress`.

### 6. Le rejeu porte sa date : `client_updated_at`

C'est la seule modification côté serveur. Un rejeu date la lecture qu'il décrit, et la garde
`ON CONFLICT … WHERE progressions.updated_at <= excluded.updated_at` refuse d'écraser une
progression plus récente. Sans ça, un épisode regardé hors ligne il y a une semaine rembobinerait
ce qu'un autre appareil a fait hier.

Le battement de coeur normal omet le champ et vaut « maintenant » : le comportement de l'endpoint
ne change pas d'un iota pour un client qui ne connaît pas ce champ.

La garde vit dans la clause `ON CONFLICT`, pas dans un lire-puis-écrire côté Go : deux appareils se
reconnectant à la même seconde liraient tous les deux « plus ancien » et écriraient tous les deux.
Une date dans le futur — appareil à l'heure fausse — est ramenée à maintenant, sinon elle épinglerait
la ligne et bloquerait toute écriture ultérieure.

### 7. La suppression reste un geste

Rien ne s'efface tout seul, même une fois vu. Un épisode vu porte sa pastille dans la liste, et
deux chemins mènent à sa suppression : l'entrée du menu de sa ligne, et un « Supprimer les vus »
en tête d'écran qui traite la fournée d'un coup. L'effacement automatique après visionnage aurait
supprimé l'épisode qu'on comptait revoir le soir même.

## Conséquences

- Une copie locale l'emporte sur le flux **même en ligne** : elle démarre sans mise en mémoire
  tampon, survit à une coupure au milieu de l'épisode, et ne coûte rien au serveur.
- Le transcodage reste une opération serveur : hors ligne, le menu Qualité ne peut rien faire. La
  copie locale est le fichier d'origine, donc c'est bien du Direct Play que l'appareil doit savoir
  décoder — ce qui, sur Android, renvoie au repli décrit par l'[ADR-0009](0009-lecteur-exoplayer-sur-android.md).
- Les sous-titres suivent le fichier pour les pistes internes, et sont rapatriés en `.vtt` pour
  celles que le serveur extrait — le lecteur les injecte déjà par leur contenu, la copie locale se
  substitue donc à l'appel réseau sans rien changer en aval.
- Le téléchargement s'arrête quand l'app s'arrête. Un service d'arrière-plan Android reste à faire.
