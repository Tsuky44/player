# ADR-0034 — Le relais de lecture ne part que sur une panne constatée

- **Statut :** accepté. En place et testé (`relay_trigger_test.dart`), pas encore observé en
  conditions réelles.
- **Date :** 2026-09-24
- **Portée :** le relais vers un serveur lié pendant une lecture
  (`app/lib/screens/player/player_screen.dart`, `_tryRelay`), son déclencheur
  (`app/lib/screens/player/playback/relay_trigger.dart`) et le pré-chauffage DNS des serveurs
  (`app/lib/services/dns_warmup_io.dart`). Précise l'ADR-0017.

## Contexte

Le relais de l'ADR-0017 reprend une lecture sur un serveur lié quand celui du compte ne répond
plus, et bascule toute l'app sur ce serveur. Il sondait le serveur du compte toutes les dix
secondes pendant toute la lecture, avec trois secondes de délai de connexion, résolution DNS
comprise.

Sur un poste Windows dont un serveur DNS ne répond pas (la box, un adaptateur VPN), chaque nom
sorti du cache met onze secondes à se résoudre. Un démarrage bloqué sur la résolution du nom du
serveur arrivait donc à la dixième seconde sans image, la sonde butait sur la même résolution et
échouait : le serveur « ne répondait plus ». La lecture partait alors sur le serveur lié, et l'app
restait branchée dessus, alors que le film était sur le serveur du compte, qui se portait bien.

## Décision

- Le relais ne s'envisage que sur une panne constatée : aucune image vingt secondes après
  l'ouverture, ou un tampon vide depuis vingt secondes. Une lecture qui reçoit ses images ne sonde
  plus rien.
- Les noms de tous les serveurs connus (comptes et serveurs liés) sont gardés dans le cache DNS du
  système. Le lecteur les résout au moment d'ouvrir le flux, et la sonde du relais aussi.

## Conséquences

- Un serveur qui tombe en plein film est remplacé au bout de vingt secondes de tampon vide, au
  lieu de dix secondes au plus. C'est le prix de ne jamais quitter un serveur qui répond.
- Un démarrage lent reste sur le serveur du compte jusqu'à vingt secondes, sous le délai de
  vingt-cinq secondes après lequel l'écran annonce l'échec.
- Le serveur du compte ne reçoit plus une requête `/api/ping` toutes les dix secondes par lecture.
