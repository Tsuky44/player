# ADR-0066 — La reprise d'un lien de partage se range sous un prénom

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** le serveur (`server/sharelinks/progress.go`,
  `server/handlers/shared_media_progress.go`, `server/handlers/shared_media.go`, la route
  `POST /api/shared/resume`, migration 24) et l'app
  (`app/lib/services/api/shared_link_client.dart`, `app/lib/models/shared_show.dart`,
  `app/lib/screens/shared_link/shared_link_screen.dart`, `shared_link_show.dart`,
  `shared_link_viewer.dart`). Supprime `app/lib/services/shared_link_progress_store.dart`.
- **Contredit l'[ADR-0037](0037-liens-de-partage-publics.md)** §5, §8 et §10, qui gardaient
  l'avancement d'un visiteur dans son seul navigateur, parce que ce choix ne tenait pas pour une
  saison regardée en plusieurs fois.

## Contexte

Un lien de saison ou de série se regarde rarement d'une traite. L'ADR-0037 gardait l'avancement
du visiteur dans le stockage du navigateur : changer d'appareil, vider ses données, ou ouvrir le
lien depuis l'app installée après le navigateur faisait repartir de « Lecture ». Et deux personnes
qui regardent le même lien sur le même appareil mélangeaient leurs avancements.

L'ADR-0037 §8 avait écarté une progression côté serveur parce qu'un visiteur n'a pas de compte
auquel la rattacher.

## Décision

### 1. Le visiteur donne un prénom, et l'avancement est rangé dessous

La page du lien demande d'abord « Votre prénom », avant la fiche et avant la lecture (avec le mot
de passe, dans le même formulaire, quand le lien en a un). Le serveur garde, **par lien et par
prénom**, une ligne par média : la position, « vu » ou non, et le moment de la dernière lecture.
Le même prénom sur le même lien, depuis n'importe quel appareil, retrouve la même reprise ; la
casse et les espaces en trop ne comptent pas (« marie » est « Marie »).

L'appareil retient le prénom donné pour ce lien et ne le redemande pas. « Vous regardez en tant
que Marie · Changer » rend la main à quelqu'un d'autre.

**Le prénom n'est pas une identité.** Il ne protège rien : quiconque a le lien (et son mot de
passe) peut taper n'importe quel prénom et voir où en est cette personne. Il range, c'est tout ;
le code du lien et son mot de passe restent la seule protection. Écarté : un code ou un jeton par
spectateur, qui aurait redonné le problème de départ (le jeton vit dans un navigateur).

### 2. Le serveur décide de « vu »

`/api/shared/progress` reçoit le prénom avec la position, et le serveur tient le média pour vu au
même seuil qu'un compte (`reachedWatchedThreshold`, 90 %). Un média vu perd sa position, un média
vu qu'on relance redevient « en cours ». Le client avance son affichage sans attendre la réponse,
et la page se réaligne sur le serveur à chaque retour du lecteur.

`/api/shared/resume` rend l'avancement d'un prénom : positions, médias vus, dernier regardé. Il
vérifie le mot de passe comme `/contents`, avec les mêmes limites. `/api/shared/open` rend en plus
la position où ce prénom s'était arrêté dans le média ouvert : c'est elle que prend le lecteur
d'un film protégé, dont la page ne pouvait rien savoir avant le mot de passe.

Rien n'est toujours écrit dans la progression ni l'historique du créateur (ADR-0037 §5).

### 3. Rien ne survit au lien

La table `media_share_progress` a une clé étrangère `ON DELETE CASCADE` vers `media_shares` :
supprimer un lien, ou le compte qui l'a créé, efface aussitôt l'avancement de ses spectateurs. Un
lien **expiré**, ou à usage unique vu depuis plus d'une heure, ne s'ouvre plus mais reste dans la
liste de son créateur ; un ménage horaire (`StartShareProgressReaper`) efface alors son
avancement. La clé vers `medias` efface aussi la ligne d'un épisode retiré de la médiathèque.

### 4. Bornes

Le lien est public : sans borne, un visiteur qui inventerait un prénom par requête remplirait la
base. Un lien tient **50 prénoms** au plus ; au-delà, un nouveau prénom n'est pas gardé (un prénom
déjà connu l'est toujours). Un prénom fait 40 caractères au plus. Le nombre de lignes par prénom
est borné par les épisodes du lien, puisque chaque position exige un ticket vivant de cet épisode.

## Conséquences

- **Une étape de plus** à la première ouverture d'un lien : taper son prénom.
- **L'avancement d'avant cette version est perdu.** Celui que les navigateurs gardaient n'est pas
  repris : « Reprendre » redevient « Lecture » une fois, le temps de relancer l'épisode.
- **Deux personnes qui donnent le même prénom partagent leur reprise.** C'est le prix d'un prénom
  sans mot de passe ; « Marie B. » suffit à les séparer.
- **Une page d'avant cette version** (un onglet resté ouvert) n'envoie pas de prénom : sa lecture
  marche, mais rien n'est gardé.
- **Le créateur voit qui regarde et où chacun en est.** `GET /api/shares` rend, pour chacun de
  ses liens, les prénoms et le dernier média de chacun (S1 E3, position ou « vu »), lus en une
  seule requête par `sharelinks.ViewersByCreator` ; l'écran « Liens de partage » les liste sous
  le lien (`app/lib/screens/settings/widgets/share_viewers.dart`). Seul le créateur les voit
  (`share_media`, ses propres liens), et ils disparaissent avec l'avancement quand le lien expire.
