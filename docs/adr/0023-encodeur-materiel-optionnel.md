# ADR-0023 — L'encodeur matériel est proposé, pas supposé

- **Statut :** accepté. La sélection, les trois encodeurs et le repli sont en place ; le défaut ne
  change pas. VAAPI reste à faire.
- **Date :** 2026-09-16
- **Portée :** le choix de l'encodeur H.264 des sessions HLS (`server/streaming/encoder.go`) et la
  construction de la commande FFmpeg. Le décodage, le graphe de filtres (redimensionnement, tone
  mapping, incrustation de sous-titres) et le chemin de repaquetage ne changent pas.

## Contexte

Le serveur encodait en `libx264` en dur, sans jamais regarder ce que la machine sait faire. Sur la
boîte de production — un Xeon sans GPU — la note du palier 2160p enregistre déjà que `veryfast`
mesure **sous le temps réel** sur une vraie source HEVC, et qu'un encodeur sous 1,0× ne rattrape
jamais un tampon perdu. L'échelle de transcodage (ADR-0022) rend par ailleurs le transcodage
nettement plus fréquent, puisqu'elle en fait la réponse normale à une liaison trop fine.

L'attente était donc « le matériel va tout régler ». La mesure dit autre chose.

Sur un Mac Apple Silicon 8 cœurs, 20 s de 2160p encodées depuis une source synthétique, décodage
exclu :

| Encodeur | Temps mur | × temps réel | CPU total | Cœurs occupés |
|---|---|---|---|---|
| libx264 `ultrafast` | 1,95 s | ×10,3 | 10,4 s | ~5,3 |
| libx264 `veryfast` | 4,41 s | ×4,5 | 30,2 s | ~6,8 |
| `h264_videotoolbox` | 8,92 s | ×2,2 | **3,7 s** | **~0,4** |

L'encodeur matériel dépense **un quatorzième du CPU** de `veryfast` et met **quatre fois plus de
temps** à le faire. Les deux chiffres sont vrais, et ils ne désignent pas le même gagnant :

- sur une machine qui a des cœurs à revendre, libx264 finit plus tôt et davantage de sessions tiennent ;
- sur un hôte sans GPU où libx264 mesure sous le temps réel, un encodeur qui ne demande presque pas
  de CPU est la différence entre transcoder et ne pas transcoder.

« Le matériel est plus rapide » n'est donc pas une propriété du matériel, mais d'une machine donnée.

## Décision

### 1. Le défaut ne change pas

`VIDEO_ENCODER` non défini vaut `libx264`, avec exactement les mêmes options qu'avant — un test les
épingle. Un serveur qui transcode correctement aujourd'hui ne doit pas changer d'encodeur parce
qu'il a été mis à jour.

`VIDEO_ENCODER=auto` prend le premier encodeur matériel qui fonctionne ; le nom d'un encodeur précis
le force. Dans les deux cas, l'échec retombe sur libx264.

### 2. Un encodeur est réputé disponible quand il a encodé une image

`ffmpeg -encoders` ne répond qu'à « qu'est-ce qui a été compilé », ce qui n'est pas la question : un
FFmpeg construit avec NVENC sur une machine sans carte NVIDIA liste `h264_nvenc` et échoue à la
première session. La détection encode donc une image et la jette. Cela coûte des millisecondes, et
c'est fait au démarrage du serveur — pas à la première lecture d'un spectateur.

### 3. Trois encodeurs, choisis pour ne rien changer au graphe de filtres

`h264_videotoolbox`, `h264_nvenc` et `h264_qsv` acceptent tous des images logicielles et les
transfèrent eux-mêmes. Le redimensionnement, le tone mapping et l'incrustation des sous-titres
restent donc strictement ce qu'ils étaient.

**VAAPI est volontairement absent.** C'est le seul qui ne prend pas d'images logicielles : il exige
un périphérique ouvert en amont et un `hwupload` ajouté à chaque chaîne de filtres — une modification
du graphe, pas d'un drapeau. À faire, séparément.

### 4. Les options propres à x264 ne partent qu'à x264

`-crf`, `-threads`, `-keyint_min` et `-sc_threshold` sont la manière dont x264 épelle « ne place pas
d'IDR où je n'en ai pas demandé ». Les encodeurs matériels n'en prennent aucune et décident eux-mêmes.

C'était le risque principal de ce chantier : si les frontières de segment dérivaient, la recherche
dériverait avec. Vérifié — `-force_key_frames`, qui est une fonction de FFmpeg lui-même et atteint
donc tous les encodeurs, suffit à les épingler. Une session réelle en `h264_videotoolbox` produit des
segments de **4,000 s exactement**, en H.264 High niveau 4.1, 8 bits 4:2:0. Un test le rejoue contre
tout encodeur matériel présent sur la machine.

### 5. Le matériel tient le débit du palier au lieu de viser une qualité

libx264 vise un CRF et plafonne le résultat ; les encodeurs matériels prennent un débit et s'y
tiennent. Le flux se pose donc **sur** le chiffre du palier au lieu de rester en dessous — ce que le
menu annonçait de toute façon depuis l'ADR-0022.

## Mesurer sur sa propre machine

Le choix dépend de l'hôte, donc la mesure aussi. Le tableau ci-dessus se reproduit ainsi :

```sh
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=3840x2160:rate=24" -t 20 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -crf 23 -b:v 0 \
  -maxrate 12M -bufsize 24M -threads 16 -an -f mp4 /dev/null
```

En remplaçant le bloc encodeur par `-c:v h264_nvenc -rc vbr -b:v 12M -maxrate 12M -bufsize 24M
-preset p4`, ou l'encodeur correspondant. Le temps « real » donne le débit, « user + sys » donne le
coût en cœurs : c'est ce second chiffre qui décide du nombre de sessions simultanées quand le
premier est confortablement au-dessus du temps réel.

## Conséquences

- Aucun changement de comportement sans action de l'opérateur.
- Un encodeur nommé mais inutilisable retombe sur libx264 **en le disant dans le journal** : encoder
  silencieusement sur le CPU donnerait l'impression que le matériel est simplement lent.
- L'encodeur retenu est résolu une fois et journalisé au démarrage.
- Le décodage reste logiciel. Un décodage matériel épargnerait davantage encore sur une source HEVC
  4K, mais il fait redescendre l'image en mémoire pour les filtres — c'est le même chantier que VAAPI.
