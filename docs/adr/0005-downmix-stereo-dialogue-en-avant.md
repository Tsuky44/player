# ADR-0005 — Le downmix stéréo passe par les niveaux de mixage, jamais par un filtre

- **Statut :** accepté — remplace le correctif audio de `30bd123`
- **Portée :** le downmix surround → stéréo, des deux côtés : le lecteur natif (libmpv) en
  Direct Play et le transcodeur (`server/streaming`) en HLS. Le web ne change pas.

## Contexte

Le correctif audio livré le 21 août partait d'une mesure fausse et d'une hypothèse invérifiée sur
l'environnement d'exécution. Les deux méritent d'être écrites, parce que chacune coûtait une
version.

### La mesure

Le correctif affirmait que FFmpeg divise un downmix par la somme de ses propres coefficients — le
centre à 0,29 contre 0,41 pour les frontales, « environ 7 dB perdus sur toute la piste » — et
corrigeait ce déficit supposé en portant les six canaux à 0,8.

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

### L'environnement

Le correctif — et la première version de cet ADR, qui n'a pas tenu une soirée — passait par un
graphe `af` : `pan` pour router les canaux, `alimiter` pour les crêtes, `aformat` pour normaliser la
disposition d'entrée.

**Le libmpv que media_kit livre pour Android est construit contre un libavfilter minimal.** Vérifié
dans le `.so` embarqué (`default-arm64-v8a.jar`) : il contient `aresample`, `volume`, `equalizer`,
`scaletempo`, `format` — et ni `pan`, ni `aformat`, ni `alimiter`. Un graphe qui les nomme ne se
dégrade pas gracieusement : mpv échoue à configurer la chaîne et le fichier se lit **sans aucun
son**, récupérable seulement par un changement de piste, qui la réinitialise.

C'est le bug rapporté depuis le début, et il n'était même pas nécessaire d'invoquer le reste : le
code lisait le nombre de canaux *après* l'ouverture pour choisir son filtre, réécrivait donc `af` en
cours de lecture — ce qui fait vider la chaîne à mpv puis reconstruire sa sortie audio
(`draining left over audio` → `Trying audio driver`) — avec 400 ms d'attente en guise de synchro,
deux appelants concurrents non attendus, et aucun effacement du filtre entre deux lectures alors que
le moteur libmpv vient de `PlayerEnginePool` et est réutilisé.

## Décision

**Trois nombres, appliqués par le rééchantillonneur, identiques des deux côtés :**

```
center_mix_level=1.0   surround_mix_level=0.7   lfe_mix_level=0.3
```

Le centre passe au niveau des frontales : **+3 dB sur les dialogues, le reste du mixage exactement
là où il était.** Les surrounds gardent leur coefficient standard ; le LFE, écarté par défaut,
revient assez bas pour donner du corps sans devenir le mixage.

- **Client** : `--audio-swresample-o`, des AVOptions posées sur le SwrContext que mpv utilise déjà
  pour convertir l'audio, avec les autres options mpv (`_applyDirectPlayPlayerProperties`,
  `_applyHlsPlayerProperties`) — donc avant chaque ouverture, jamais pendant la lecture.
- **Serveur** : un `-filter:a:N aresample=…` portant les mêmes trois nombres, uniquement sur les
  renditions à plus de deux canaux.

Ce qui rend cette forme correcte là où le graphe ne l'était pas :

- **Rien à installer.** La correction voyage sur la conversion que mpv (ou FFmpeg) allait faire de
  toute façon. Aucun filtre à nommer, donc aucun filtre à manquer.
- **Rien à savoir de la piste.** Les niveaux de mixage s'appliquent à la disposition qui se
  présente, quelle qu'elle soit ; une piste déjà stéréo traverse sans être touchée. Il n'y a plus
  d'indice de canal à deviner, donc plus de raison de lire quoi que ce soit après l'ouverture.
- **Inerte quand il le faut.** swresample ne rematrixe que s'il convertit réellement une
  disposition. Sur une machine reliée à un ampli, où mpv envoie les six canaux tels quels, ces
  niveaux ne sont jamais consultés : le surround de celui qui a le matériel pour n'est pas replié
  dans son dos, et aucun test de plateforme n'est nécessaire pour l'obtenir.
- **Sans option datée.** La disposition de sortie n'est pas nommée : `-ac:a:N 2` la fournit déjà
  côté serveur, et l'option qui l'épelle a été renommée entre deux versions de FFmpeg
  (`ocl` → `ochl`).

## Conséquences

- Plus aucune écriture de `af`, nulle part. La disparition du son n'a plus de mécanisme, ni sur
  Android (filtre absent) ni ailleurs (reconstruction de la sortie audio en cours de film).
- Un même fichier sonne pareil qu'il soit lu directement ou transcodé : vérifié bout en bout sur un
  mixage type film, −13,5 dB en Direct Play contre −13,3 dB via HLS.
- Les dialogues gagnent 3 dB et rien d'autre ne bouge, sur toutes les plateformes — le desktop
  compris, où le réglage ne se manifeste que quand mpv replie effectivement du surround.
- Si le téléphone reste « étouffé » après ça, la cause n'est pas le downmix : la ligne
  `Audio: Nch source → Nch out` ajoutée au journal de lecture dit si l'appareil a reçu six canaux et
  les a repliés, ou une stéréo déjà repliée par le serveur — et c'est par là qu'il faudra reprendre.
- Le serveur doit être redéployé pour que la moitié HLS du correctif existe sur le téléphone.

## Note pour la suite

Le libavfilter minimal d'Android est une contrainte permanente de ce lecteur, pas un détail de ce
correctif. Toute future idée passant par `--af` — égalisation, normalisation de la dynamique,
compression nocturne — doit être vérifiée dans le `.so` livré avant d'être écrite, et échouera de la
même manière si elle ne l'est pas : silence complet, pas message d'erreur.
