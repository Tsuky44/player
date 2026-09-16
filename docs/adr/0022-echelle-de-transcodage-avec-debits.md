# ADR-0022 — Le menu de qualité est une échelle de débits, pas une liste de résolutions

- **Statut :** accepté. L'échelle est servie par le serveur et affichée par les deux menus.
- **Date :** 2026-09-16
- **Portée :** les paliers de transcodage (`server/streaming/quality.go`), leur publication dans la
  réponse des pistes, et les deux menus de qualité du lecteur. Le choix direct play / HLS ne change
  pas — voir « Ce que cet ADR ne résout pas ».

## Contexte

Le serveur offrait cinq paliers : 360p, 480p, 720p, 1080p, 2160p. Un par résolution, un débit par
palier, et aucun de ces débits écrit nulle part dans l'interface.

Cela laisse un spectateur coincé. Une lecture qui se coupe est une lecture qui demande plus que la
ligne ne porte ; or le seul cran plus bas que 1080p était 720p, qui jette la moitié des lignes pour
résoudre un problème qui n'a jamais été une affaire de lignes. Entre « 1080p à 6 Mbit/s » et « 720p
à 3,5 Mbit/s » il manquait tout ce qui compte : 1080p à 4, à 2.

Les deux menus écrivaient leur liste à la main, et ils avaient déjà divergé du serveur : le panneau
de réglages annonçait « 4K — débit réduit (~8 Mb/s) » pour un palier encodé à 12 Mbit/s.

Un journal de lecture réelle sur une liaison contrainte :

```
Playback: 3840x2160 H.265 / HEVC @ 23.976fps · hwdec=d3d11va
mpv: la connexion ne suit pas le débit — reprise après 5s en mémoire
mpv: la connexion ne suit pas le débit — reprise après 10s en mémoire
mpv: la connexion ne suit pas le débit — reprise après 20s en mémoire
```

`CachePausePolicy` était montée à son palier maximum : trois coupures rapprochées, la ligne ne tient
pas le débit du fichier. Le spectateur n'avait aucun moyen de savoir combien demander à la place.

## Décision

### 1. Un palier est une résolution **et** un débit

Seize barreaux au lieu de cinq, groupés là où les liaisons réelles se trouvent — autour de 20 et 10
pour une bonne fibre, 6 et 4 pour un envoi ordinaire, 2 et 1 pour un partage de connexion ou un
envoi saturé.

### 2. Les cinq clés d'origine gardent leurs chiffres exacts

`360p`, `480p`, `720p`, `1080p`, `2160p` conservent leur clé et leur débit. Des clients déjà
installés envoient ces chaînes, et un palier dont le débit changerait sous eux serait une régression
livrée sous forme de mise à jour. Un test les épingle.

### 3. L'échelle est triée par débit décroissant, pas par résolution

C'est tout l'intérêt : le spectateur choisit contre une connexion, donc « le cran en dessous » doit
vouloir dire « demande moins à la ligne ». Un menu où 360p se serait retrouvé sous un palier 480p
moins cher aurait menti sur le sens de la descente. À débit égal, la plus grande image passe devant.

### 4. C'est le serveur qui compose le libellé

Lui seul sait à quel débit il encode. Le libellé voyage entier (« 1080p · 6 Mbit/s ») et les menus le
coupent au séparateur pour la mise en page ; aucun client ne reformate le nombre. C'est la réponse
directe au « ~8 Mb/s » qui en annonçait 8 pour 12.

### 5. L'échelle voyage avec la liste des pistes

`GET /api/media/:id/tracks` la porte, parce que le menu est construit avant qu'une session existe et
doit être juste à sa première ouverture. Étant par média, les barreaux au-dessus de la source en sont
retirés : proposer de la 4K pour un fichier 1080p, c'est proposer un agrandissement — du débit dépensé
en pixels inventés, et côté serveur un redimensionnement qui interdit le repaquetage.

Le seuil qui décide du palier natif d'une source est celui que le client utilise déjà
(`qualityForSourceHeight`). Les garder identiques évite qu'un menu refuse le palier qui est en train
d'être lu.

### 6. Un serveur sans échelle garde un menu utilisable

Une médiathèque peut réunir plusieurs serveurs (ADR-0013). Un serveur plus ancien ne renvoie rien, et
les deux menus retombent sur leur liste de cinq.

## Ce que cet ADR ne résout pas

Le choix entre lecture directe et HLS reste pris par le client sur les seuls **codecs** : il joue en
direct dès qu'il sait décoder le fichier. La bande passante n'entre nulle part dans cette décision.

Le serveur a pourtant un plafond prévu pour ça — `defaultCopyBitrateCeiling`, 12 Mbit/s — mais il ne
vit que sur le chemin HLS, que le client ne prend jamais dans ce cas. Le garde-fou existe et n'est
jamais atteint.

Cet ADR donne donc au spectateur de quoi corriger la situation à la main, avec les chiffres sous les
yeux. Il ne la corrige pas tout seul. Un choix qui tiendrait compte du débit mesuré est une décision
séparée, côté client.

## Conséquences

- Le menu passe de 5 à 16 entrées sur une source 4K, 13 sur une source 1080p, 8 sur une 720p.
- Les deux menus lisent la même échelle : ils ne peuvent plus diverger du serveur ni l'un de l'autre.
- Un nouveau palier s'ajoute à un seul endroit, `qualityLadder`, et apparaît partout.
- Les barreaux 4K héritent de `ultrafast` comme le palier d'origine, pour les raisons mesurées qui
  sont notées sur `uhd()` : au-dessous du temps réel, un encodeur ne rattrape jamais un tampon perdu.
