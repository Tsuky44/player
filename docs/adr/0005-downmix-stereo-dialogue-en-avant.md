# ADR-0005 — Un seul graphe de downmix, posé avant l'ouverture du flux

- **Statut :** accepté — remplace le correctif audio de `30bd123`
- **Date :** 2026-08-23
- **Portée :** le downmix surround → stéréo, des deux côtés : le lecteur natif (libmpv) en
  Direct Play et le transcodeur (`server/streaming`) en HLS. Le web ne change pas.

## Contexte

Le correctif audio livré le 21 août partait d'une mesure fausse. Il affirmait que FFmpeg divise un
downmix par la somme de ses propres coefficients — le centre à 0,29 contre 0,41 pour les frontales,
« environ 7 dB perdus sur toute la piste » — et corrigeait ce déficit supposé en portant les six
canaux à 0,8.

Cette division existe, mais elle ne s'applique **que lorsque le résultat atterrit dans un format
entier**. Le chaînage audio de mpv travaille en flottant, l'encodeur AAC du serveur aussi. Sur les
deux chemins qui nous concernent, il n'y a donc aucune atténuation à récupérer. Mesuré (mpv,
`--ao=pcm`, source 5.1 canal par canal) :

| | frontales | centre |
|---|---|---|
| downmix par défaut | unité | 0,707 (−3 dB) |
| filtre livré le 21 août | −1,9 dB | −1,9 dB |

Le correctif rendait donc le film **plus faible de 2 dB** pour gagner 1 dB sur les voix. Le seul
défaut réel est ce −3 dB sur le centre, qui est le canal des dialogues : c'est peu, mais c'est
exactement ce qu'on entend comme « étouffé » sur un téléphone, où la stéréo est la seule sortie.

Le coût, lui, n'était pas de 2 dB. Le filtre était choisi d'après le nombre de canaux, or ce nombre
n'est lisible qu'une fois que mpv a configuré la piste — après l'ouverture du fichier. Le code le
lisait donc *après coup* et réécrivait `af` en cours de lecture, avec 400 ms d'attente en guise de
synchronisation et deux appelants concurrents non attendus. Trois défauts en découlaient :

- Écrire `af` pendant la lecture fait vider la chaîne de filtres à mpv puis **reconstruire la sortie
  audio** (`draining left over audio` → `Trying audio driver` dans son journal). Sur l'AudioTrack
  d'Android, cette réinitialisation peut échouer : le film continue, sans aucun son. Le seul retour
  en arrière est un changement de piste, qui réinitialise la chaîne — c'est le contournement avec
  lequel le bug a été rapporté.
- Le moteur libmpv vient de `PlayerEnginePool` et est réutilisé. Rien n'effaçait le filtre entre deux
  lectures : un graphe écrit pour un 5.1 restait installé quand le fichier suivant, ou une bascule
  vers HLS, configurait une piste stéréo.
- `pan` adresse les canaux par indice. Un graphe écrit pour six canaux appliqué à une piste qui n'en
  a qu'un ne laisse du son que sur une enceinte.

## Décision

**Un seul graphe, constant, identique côté client et côté serveur :**

```
aformat=channel_layouts=5.1,
pan=stereo|c0=1.0*c0+1.0*c2+0.7*c4+0.3*c3|c1=1.0*c1+1.0*c2+0.7*c5+0.3*c3,
alimiter=limit=0.95:level=0
```

`aformat` est ce qui rend le graphe constant. Il convertit ce que sort le décodeur en 5.1 *avant*
`pan`, donc `c0`..`c5` existent toujours et désignent toujours la même chose. Une piste stéréo est
remontée en 5.1 puis repliée telle quelle — mesuré identique à l'absence de filtre ; une piste mono
arrive au centre et ressort des deux enceintes ; du 7.1 est replié en 5.1 par la conversion que mpv
aurait faite de toute façon. La question « 5.1 ou 5.1(side) » disparaît avec, puisque plus aucun
canal n'est nommé.

Le centre passe à 1.0, au niveau des frontales : **+3 dB sur les dialogues, le reste du mixage
exactement là où il était.** `alimiter` paie les coefficients qui peuvent désormais dépasser 1,0.

Parce que le graphe ne dépend plus de la piste, il est posé **avant `open()`** et jamais pendant la
lecture : avant chaque ouverture Direct Play, avant chaque session HLS, avant le retour au Direct
Play. Écrit à vide comme à plein — un moteur mis en pool ne doit hériter de rien. Il n'y a plus de
lecture de propriété, plus de délai de 400 ms, plus d'appelants concurrents, et plus de
reconstruction de la sortie audio en cours de film.

Côté client, le filtre ne s'applique qu'à un appareil dont la sortie *est* une paire stéréo :
téléphone ou tablette, hors mode TV. Un desktop peut être relié à un ampli et un téléviseur l'est
presque toujours ; replier six canaux avant le matériel capable de les jouer reviendrait à jeter ce
pour quoi il a été acheté. Les deux gardent le downmix de mpv, qui est le downmix standard et n'a
jamais été ce dont on se plaignait.

## Conséquences

- Le PC ne touche plus du tout à `af`. La disparition du son constatée en Direct Play comme après
  une bascule de qualité n'a plus de mécanisme.
- Un même fichier sonne pareil qu'il soit lu directement ou transcodé : les deux moitiés portent les
  mêmes coefficients (vérifié bout en bout, +2,3 dB sur un mixage type film des deux côtés).
- Les dialogues gagnent 3 dB et rien d'autre ne bouge. Si le téléphone reste « étouffé » après ça,
  la cause n'est pas le downmix : la ligne `Audio: Nch source → Nch out` ajoutée au journal de
  lecture dit si l'appareil a reçu six canaux et les a repliés, ou une stéréo déjà repliée par le
  serveur — et c'est par là qu'il faudra reprendre.
- Le serveur doit être redéployé pour que la moitié HLS du correctif existe sur le téléphone.
