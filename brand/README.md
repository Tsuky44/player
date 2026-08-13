# Marque Onyx

La marque est une lentille de projection : un cercle, un triangle play, et un
faisceau qui part large au niveau de la lentille et se resserre en s'éloignant
vers la droite. Le triangle play et la source du faisceau sont le même objet —
c'est ce qui rend le logo lisible immédiatement.

Palette : `#e8e6e4` sur `#121414`, intérieur de lentille `#0e1010`. Aucun
dégradé sauf le faisceau, aucune texture.

## Fichiers

| Fichier | Usage |
| --- | --- |
| `onyx-lockup.svg` | Marque + wordmark, fond charbon. Splash, écran de connexion, docs. |
| `onyx-mark.svg` | Marque seule, fond transparent. |
| `onyx-wordmark.svg` | Wordmark seul, fond transparent. |
| `onyx-icon.svg` | Tuile à coins arrondis, tout usage. |
| `onyx-icon-square.svg` | Plein cadre — Android, icônes web, favicon. |
| `onyx-icon-maskable.svg` | Plein cadre, marque dans la zone sûre 80% — icônes maskable PWA. |
| `onyx-icon-macos.svg` | Squircle inséré selon la grille d'icônes d'Apple, fond transparent. |

Le wordmark est **vectorisé** : les lettres sont des tracés, pas du texte. Rien
à installer, rendu identique partout. Les veines ou effets de matière ne font
pas partie de la marque.

## Régénérer les icônes d'app

```bash
./brand/generate-icons.sh
```

Le script n'utilise que des outils livrés avec macOS (`qlmanage`, `sips`,
`python3`) et écrit dans `app/macos`, `app/android`, `app/web` et
`app/windows`. Il faut donc le lancer depuis un Mac.

## Dans l'app

La marque n'est pas embarquée en SVG : elle est redessinée à l'identique en
`CustomPainter` dans `app/lib/widgets/global/onyx_mark.dart`, ce qui évite
d'ajouter `flutter_svg` au pubspec. Si la géométrie des SVG change ici, il faut
reporter la modification là-bas.

`OnyxMark(showBeam: false)` ne dessine que la lentille : sous ~40px de haut, le
faisceau n'est plus qu'un aplat gris et dessert la marque.
