# ADR-0048 — Un seul lecteur : le Chrome Onyx

- **Statut :** accepté. `flutter analyze`, `flutter test`, `go vet` et `go test` sont verts ; le
  lecteur n'a pas été revu à l'écran sur chaque cible après le retrait.
- **Date :** 2026-10-06
- **Portée :** `app/lib/screens/player/player_screen.dart`,
  `app/lib/screens/player/widgets/onyx/`, `app/lib/screens/player/subtitle_padding.dart`,
  la page de réglages « Lecture », `app/lib/services/download_manager_io.dart`,
  `server/main.go`, `server/database/migrations.go` (migration 19).

## Contexte

Le lecteur avait trois habillages, choisis par une préférence de compte : un HUD par défaut, une
couche de contrôles placés librement, et le Chrome Onyx. Un éditeur permettait de composer la
deuxième, et les dispositions étaient enregistrées sur le compte, synchronisées entre appareils et
figées à côté des téléchargements pour la lecture hors ligne.

Chaque correctif d'interaction devait être fait trois fois, et ne l'était pas : le fondu, le
scrubber, le focus à la télécommande et les encoches n'étaient corrects que dans le Chrome Onyx. Le
téléviseur l'imposait déjà, les liens de partage aussi. Le HUD par défaut — celui d'une installation
neuve — était le moins soigné des trois.

## Décision

**Le lecteur n'a qu'un chrome, le Chrome Onyx, le même pour tous les comptes et tous les
appareils.**

- `PlayerScreen` monte `OnyxControlsLayer` sans condition. Il n'y a plus de préférence de chrome à
  lire, ni par compte, ni par appareil, ni par téléchargement.
- L'éditeur de disposition, les modèles, les habillages de contrôles, le HUD par défaut et leurs
  panneaux de réglages sont retirés, avec leur modèle, leur fournisseur et leur stockage local.
- Le serveur ne sert plus les routes des dispositions par compte, et la migration 19 retire leur
  table. Une base neuve ne la crée plus.
- La page de réglages « Lecture » perd son groupe « Interface du lecteur ».
- Le décalage des sous-titres au-dessus de la barre de lecture garde son calcul
  (`SubtitlePaddingCalculator`), réduit à la mesure de la barre du Chrome Onyx.

Contredit, pour ce qui touche aux autres habillages, les ADR-0006, 0010, 0016, 0024, 0025, 0029 et
0043 : ce qu'elles disent des dispositions placées librement, du HUD par défaut, de l'éditeur et du
chrome figé à côté des téléchargements ne s'applique plus. Le reste de chacune tient.

## Conséquences

- Un correctif du lecteur se fait une fois. `app/test/single_player_chrome_test.dart` échoue si une
  deuxième couche de contrôles revient ou si l'écran du lecteur en monte une autre.
- Le bouton « Extraire les sous-titres » n'existait que dans les panneaux retirés ; le menu du
  Chrome Onyx ne l'a pas. L'extraction de fond lancée par le lecteur reste.
- Le lecteur ne pose plus de verre groupé sur le film : son `BackdropGroup` est retiré, et la
  coquille de l'app reste le seul écran à en ouvrir un (ADR-0025).
- Une app plus ancienne branchée sur un serveur à jour reçoit un 404 sur les routes retirées. Elle
  le traite déjà comme une synchronisation impossible et garde sa disposition locale.
- Les dispositions enregistrées sont perdues, sans export. Sur les appareils, les anciennes clés de
  préférences et le fichier `chromes.json` des téléchargements restent sur le disque, sans lecteur.
