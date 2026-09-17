# ADR-0024 — Le curseur est à nous, pas à Material

- **Statut :** accepté. Le widget est en place et les sept curseurs de l'application passent par
  lui. Mesuré sur banc d'essai ; à revalider sur une vraie session Windows.
- **Date :** 2026-09-17
- **Portée :** les curseurs de l'interface (`app/lib/widgets/global/app_slider.dart` et ses sept
  appelants : volume des deux chromes du lecteur, chrome global, quatre réglages du studio). La
  barre de progression du lecteur (`emby_progress_bar.dart`) et le curseur de luminosité
  (`emby_brightness_slider.dart`) étaient déjà des dessins maison et ne changent pas.

## Contexte

Sous Windows, la sortie d'erreur de l'application se remplissait sans fin de :

```
[ERROR:flutter/shell/platform/common/accessibility_bridge.cc(114)]
Failed to update ui::AXTree, error: Nodes left pending by the update: 1609
```

Le symptôme visible n'était pas l'accessibilité mais la fluidité : dès qu'une page à gros arbre
était à l'écran — une fiche de détail, ses acteurs et ses suggestions — toute l'application
ramait. En debug, chaque ligne est une écriture console synchrone, et il y en a une par image.

La cause est le `Slider` de Material. Il enveloppe toujours son résultat dans un `OverlayPortal`,
même quand aucun indicateur de valeur n'est demandé. Dans une **route poussée** — le lecteur, le
studio — ce portail sérialise un nœud sémantique que personne ne réclame comme enfant, et
l'embarqueur Windows refuse alors la mise à jour **entière** de l'arbre. Le refus n'est pas
ponctuel : l'arbre reste figé, chaque image réessaie, chaque image échoue. Voir
[flutter#190357](https://github.com/flutter/flutter/issues/190357), ouvert et non corrigé.

Un banc d'essai jetable — Flutter 3.44.4, un curseur dans une route poussée, valeur changée trois
fois par seconde pendant huit secondes, accessibilité forcée par `ensureSemantics()` — compte les
erreurs produites :

| Variante | Erreurs `AXTree` |
|---|---|
| `Slider` de Material | 23 |
| `MergeSemantics` autour | 23 |
| `Semantics(...)` autour d'un `ExcludeSemantics` | 23 |
| `ExcludeSemantics` seul | 2 |
| aucun `Slider` (barre de progression nue) | 0 |
| le curseur de cet ADR | **0** |

Deux enseignements. Masquer le sous-arbre atténue sans régler, et coûte l'annonce du contrôle aux
lecteurs d'écran. Surtout : ré-emballer ce masquage dans un `Semantics` explicite, pour garder
cette annonce, **ramène les 23 erreurs** — le nœud orphelin retrouve un parent à qui s'accrocher.
Il n'existe donc pas d'arrangement des sémantiques qui garde à la fois le `Slider` et l'arbre.

## Décision

### 1. Un curseur dessiné par l'application

`AppSlider` peint sa piste, sa partie active et son pouce dans un `CustomPaint`, écoute les
gestes, et n'ouvre aucun portail. C'est la seule façon de ne pas produire le nœud fautif.

### 2. L'habillage reste celui du `SliderTheme` ambiant

Hauteur de piste, couleurs, rayon du pouce et rayon du halo sont lus dans le `SliderTheme` du
contexte, exactement comme le ferait un `Slider`. Les appelants qui en posaient un — tous — gardent
leur allure sans une ligne de changement chez eux.

Les règles de taille sont celles de Material : la place offerte quand elle est bornée, sinon la
hauteur des pièces dessinées et 144 pixels de large (trois cibles tactiles). Une barre de contrôle
ne se réorganise donc pas parce que le curseur a changé.

### 3. Les sémantiques sont décrites, pas supprimées

Le nœud annonce un curseur, sa valeur en pourcentage, les deux valeurs voisines et les deux actions
qui y mènent. Flèches gauche/droite/haut/bas, `Home` et `Fin` fonctionnent, au dixième de la course
— le pas de Material quand il n'y a pas de graduations.

### 4. Ce qui n'est pas repris

Les graduations (`divisions`), l'indicateur de valeur au-dessus du pouce et les animations de
pression de Material. Aucun appelant ne s'en servait. Le jour où il en faut, c'est ici que ça
s'ajoute, sans portail.

## Conséquences

- Le flot d'erreurs disparaît, et avec lui la cause console du ralentissement sous Windows.
- L'arbre d'accessibilité cesse d'être figé : ce qui est annoncé le reste sur **toutes** les pages,
  pas seulement là où il y a un curseur.
- Un curseur de plus dans l'application doit passer par `AppSlider`. Un `Slider` de Material posé
  dans une route poussée ramène le gel, silencieusement, et le symptôme ne ressemble pas à sa
  cause.
- `app/test/app_slider_test.dart` tient les cinq promesses : aucun `Slider` de Material dessous,
  l'annonce et ses deux actions, le clic sur la piste, la flèche, et l'état désactivé.

## À vérifier

- Une vraie session Windows avec un client d'accessibilité attaché, sur une fiche de détail puis
  dans le lecteur : plus aucune ligne `Nodes left pending`.
- Il reste [flutter#182444](https://github.com/flutter/flutter/issues/182444), l'autre forme
  (`N will not be in the tree`), causée par les `Tooltip` d'une liste. Si elle apparaît, elle se
  traite séparément — le banc d'essai est fait pour ça.
- Si Flutter corrige #190357, ce widget reste tout de même le nôtre : revenir à Material coûterait
  un aller-retour pour rien.
