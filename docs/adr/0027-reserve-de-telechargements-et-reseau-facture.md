# ADR-0027 — Réserve de téléchargements, et réseau facturé

- **Statut :** accepté, réalisé
- **Date :** 2026-09-18
- **Portée :** l'app cliente (Android, iOS, macOS, Windows). Aucune modification serveur : tout
  s'appuie sur des routes existantes. Le web n'a pas de stockage applicatif et reste inchangé.
- **Prolonge :** [ADR-0010](0010-telechargements-hors-ligne.md)

## Contexte

L'ADR-0010 a donné à l'app un bouton par média. C'est le bon geste pour un film ; c'en est un
mauvais pour une série, parce qu'il ne correspond à rien de ce qu'on fait réellement.

Ce qu'on fait réellement, c'est : *avant de partir*, rapatrier cinq épisodes ; en regarder trois
dans le train ; et se retrouver le lendemain avec deux épisodes d'avance et aucune envie d'y
repenser. Le geste est donc toujours le même — **remettre de l'avance** — et il tombe toujours au
plus mauvais moment, c'est-à-dire quand on a du réseau mais pas la tête à ça.

Deux choses manquaient donc :

1. **la saison d'un coup** : vingt appuis sur vingt lignes font exactement la même chose ;
2. **la réserve qui se remplit toute seule** : l'avance consommée se reconstitue sans qu'on la
   redemande.

Et une troisième, qui n'est pas une commodité mais un garde-fou : un épisode est rapatrié dans sa
qualité d'origine, sans compression (ADR-0010 §1). **Plusieurs gigaoctets.** Une réserve qui se
remplit toute seule sur un forfait mobile est une facture, pas une fonctionnalité.

## Décision

### 1. Une réserve d'avance, exprimée en épisodes non vus

Le réglage est un nombre : *combien d'épisodes non vus garder sur l'appareil*. Quatre par défaut.

Dès qu'il en reste moins, les suivants descendent. Pas « quand il n'en reste qu'un », pas « par
paquets de deux » : dès qu'il en manque. C'est la seule formulation qui tienne la promesse — *il y
a toujours quatre épisodes d'avance* — et c'est aussi la plus simple à se représenter, ce qui
compte pour un réglage qu'on tourne une fois et qu'on oublie.

Comptent comme de l'avance les épisodes non vus qui sont sur l'appareil **ou en route**. Un
transfert en cours sera là avant qu'on en ait besoin ; ne pas le compter ferait descendre la saison
entière en une salve. Ne comptent pas un épisode en échec ni un épisode mis en pause à la main :
ni l'un ni l'autre n'arrive nulle part tout seul.

### 2. La règle ne s'amorce jamais d'elle-même

Elle ne s'applique qu'aux séries **dont un épisode a déjà été téléchargé**. Le premier épisode
reste un geste, toujours.

C'est ce qui empêche la fonctionnalité d'être une surprise : une app qui se met à rapatrier une
série qu'on vient d'ouvrir dans le catalogue n'est pas prévenante, elle est envahissante. Un
téléchargement manuel, lui, est un signal net — *je suis en train de regarder ça, et je compte le
regarder ailleurs qu'ici*.

Un troisième mode existe pour ceux qui le veulent (« toute la série »), et un mode « désactivé »
pour ceux qui n'en veulent pas.

### 3. La suite se demande au serveur, épisode par épisode

`GET /api/episodes/:id/next` — la route dont le lecteur se sert déjà pour enchaîner. On repart du
dernier épisode connu de la série sur l'appareil et on avance.

L'avantage sur « lister la saison et prendre les suivants » est le passage de saison : le serveur
sait déjà le faire, et il est le seul à savoir ce qu'il possède réellement. Un épisode déjà là est
enjambé, un épisode déjà vu aussi, un épisode absent du serveur également — la marche continue
jusqu'à avoir le compte, ou jusqu'à la fin de la série.

Le mode « toute la série » passe, lui, par les saisons (`/api/shows/:id/seasons`) : il ne s'agit
plus d'avancer, mais de tout prendre.

### 4. Rien ne s'efface, et un effacement se retient

La réserve remplit ; elle ne vide pas. La suppression reste un geste (ADR-0010 §9).

Mais un effacement dit quelque chose, et il fallait l'écouter : **supprimer un épisode qu'on n'a
pas vu**, c'est faire de la place, et une réserve qui le rapatrierait au tour suivant ne ferait
jamais de place. Ces identifiants-là sont donc retenus — dans le manifeste, pour survivre au
redémarrage, parce que c'est le lendemain avec un disque plein que ça compte. Redemander le média
explicitement annule la réponse. Supprimer un épisode **vu** ne dit rien de plus que « c'est vu »,
et n'est pas retenu.

### 5. Le réseau se paie à l'octet, ou pas

Deux questions distinctes, et c'est la seconde qui rend la première utile :

- `connectivity_plus` dit le **type** de réseau : Wi-Fi, Ethernet, données mobiles, rien ;
- sur Android, `ConnectivityManager.isActiveNetworkMetered` dit si le réseau **actif est facturé**.

La seconde attrape le cas que la première laisse passer, et c'est justement le plus coûteux : un
téléphone raccordé au **partage de connexion** d'un autre voit du Wi-Fi et rien d'autre, alors que
les octets sortent d'un forfait. Un VPN par-dessus le Wi-Fi, à l'inverse, ne compte pas : Android
annonce alors `[vpn]` ou `[vpn, wifi]`, et refuser de télécharger parce que quelqu'un a allumé son
VPN chez lui serait absurde.

Sur un réseau facturé, trois réponses possibles, réglables : **demander** (par défaut),
**télécharger**, **Wi-Fi uniquement**. La boîte de dialogue offre trois sorties et pas deux, parce
qu'il y a trois intentions : télécharger quand même (l'autorisation vaut pour la session, pas pour
toujours), **attendre le Wi-Fi** — le téléchargement est bien demandé et partira tout seul —, ou
annuler.

C'est cette troisième sortie qui rend la question supportable. Sans elle, refuser signifierait
revenir le relancer à la main, c'est-à-dire exactement ce que la réserve existe pour éviter.

### 6. Ce n'est pas la joignabilité du serveur

L'ADR-0010 §6 tranche que la joignabilité se mesure sur `GET /api/ping` et non sur un état de
connectivité système, parce qu'avoir du réseau n'est pas avoir *ce* serveur. Rien ne change :
`NetworkStatus` répond à une **autre** question — *sur quoi passent les octets* — que le ping ne
sait pas poser. Un NAS joignable en 4G est parfaitement joignable ; y rapatrier une saison vide un
forfait.

Les deux cohabitent sans se recouvrir : le serveur décide si l'app est utilisable, le réseau décide
si la file a le droit de tourner.

### 7. La garde est posée entre deux médias, pas à la mise en file

Le magasin hors ligne demande à chaque tour de file : *ai-je le droit maintenant ?* La question est
posée **dehors** (`transferGate`), parce que ce qui décide est le croisement d'un état réseau et
d'un réglage utilisateur, deux choses dont le magasin n'a pas à connaître l'existence.

Ce qui a été demandé reste demandé. Passer en 4G au milieu d'une saison arrête la suite sans rien
perdre ; le retour d'un réseau libre relance la file exactement là où elle en était, à l'octet près
puisque le transfert est un `Range:` en append (ADR-0010 §1). Aucun statut « en pause automatique »
n'est introduit : les entrées restent en file, qui est précisément ce qu'elles sont.

## Conséquences

- Le réglage vit sur **l'appareil**, comme le profil de lecture ([ADR-0004](0004-profil-de-lecture-par-appareil.md)) :
  c'est ce téléphone-ci qui a un forfait et ce disque-là qui se remplit, pas le compte.
- La réserve ne tourne que serveur joignable — il faut bien demander la suite à quelqu'un. Hors
  ligne, le plan est simplement remis au retour du serveur, pas perdu.
- iOS, macOS et Windows n'ont pas d'équivalent à `isActiveNetworkMetered` : sur ces plateformes, un
  partage de connexion en Wi-Fi passe pour du Wi-Fi. Le réglage « Wi-Fi uniquement » n'y protège
  donc que des données mobiles. C'est assumé : sur macOS et Windows le cas est marginal, et sur iOS
  il demanderait un `NWPathMonitor` natif pour le seul `isExpensive`.
- Le téléchargement s'arrête toujours quand l'app s'arrête (ADR-0010) : la réserve se remplit app
  ouverte. Un service d'arrière-plan Android reste à faire, et il vaut maintenant plus qu'avant.
- Le mode « toute la série » peut mettre plusieurs centaines de gigaoctets en file. Il est écrit
  dans les réglages qu'il est fait pour les séries qu'on emporte, pas pour toutes.
