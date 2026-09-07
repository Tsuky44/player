# ADR-0012 — L'image dans l'image, sur Android seulement

- **Statut :** accepté, réalisé — vérification sur appareil encore à faire
- **Date :** 2026-09-07
- **Portée :** le lecteur sur téléphone. Rien sur téléviseur, rien sur ordinateur.

## Contexte

Quitter l'app pendant un épisode l'arrêtait. C'est le geste le plus courant qu'on fasse d'un
téléphone — répondre à un message, regarder l'heure — et tous les lecteurs de la plateforme y
répondent de la même façon : le film continue dans une petite fenêtre posée au-dessus du reste.

## Décision

### 1. La fenêtre est *armée*, pas ouverte

Android ne laisse créer la fenêtre qu'à l'instant précis où l'utilisateur s'en va —
`onUserLeaveHint`, et depuis Android 12 le système le fait lui-même sur le geste d'accueil. Il n'y a
pas de « passe en petit maintenant » qu'on pourrait appeler après coup.

Donc le lecteur **donne la forme du film à l'avance** et l'activité garde ce rapport ; c'est le
système qui décide du moment. Un aller-retour vers Dart au moment du départ arriverait après la
fenêtre. À partir d'Android 12, `setAutoEnterEnabled` fait mieux qu'entrer au bon moment : il fait
voler l'image jusque dans le coin au lieu de l'y faire apparaître.

Le rapport d'image est ramené dans ce qu'Android accepte — 1:2.39 à 2.39:1 — **par valeur
inférieure** : le format scope est exactement à la limite, et un arrondi au plus proche tombe une
fois sur deux du mauvais côté, ce qu'Android ne pardonne pas (il lève une exception au lieu de
recadrer).

### 2. Dans la fenêtre, il n'y a que l'image

La même vue Flutter est simplement dessinée plus petite : ni le chrome, ni les gestes, ni les
incrustations n'y ont de place — ni de quoi être touchés. Le lecteur ne dessine donc que l'image
tant qu'il y est, et l'arbre de widgets garde la vidéo à la même place dans sa liste : la
reconstruire ailleurs démonterait la vue de plateforme et rebrancherait la surface, ce qui se verrait
comme un clignotement dans le coin de l'écran d'accueil.

**Fermer la fenêtre met en pause.** Le système distingue « restaurée » de « fermée » par l'état du
cycle de vie au moment où l'on en sort ; un film qui n'a plus nulle part où jouer ne doit pas
continuer à jouer.

### 3. Rien sur iOS, et ce n'est pas un oubli

iOS a la même fonction et ce n'est pas le même mécanisme : `AVPictureInPictureController` met à
l'écran une **couche AVFoundation**. Ce lecteur rend par mpv dans une texture Flutter (ADR-0011),
qui n'en est pas une. Y arriver demanderait de livrer les images décodées à un
`AVSampleBufferDisplayLayer`, ou de lire par `AVPlayer` — que l'ADR-0011 a précisément écarté parce
qu'il refuse le MKV, et qu'une grande partie d'une bibliothèque privée est en MKV.

Ce n'est donc pas une ligne à ajouter : c'est un second chemin de rendu à écrire. La décision est de
ne pas le faire tant que le reste de la cible iOS n'a pas tourné sur appareil.

### 4. Ni téléviseur, ni ordinateur

Android TV a sa propre idée de la fenêtre et un chrome qui n'est pas fait pour elle ; un ordinateur
a déjà des fenêtres, et le lecteur y est déjà l'une d'elles.

## Conséquences

- Le manifeste déclare `supportsPictureInPicture` **et** `resizeableActivity` : une activité non
  redimensionnable ne peut pas entrer dans la petite fenêtre. Les `screenSize|screenLayout|
  smallestScreenSize` déjà présents dans `configChanges` sont ce qui empêche l'activité d'être
  recréée quand elle y est redimensionnée — ce qui relancerait la lecture au lieu de la continuer.
- La forme est la seule partie vérifiable sans appareil, et elle est couverte par des tests.
  Le reste — l'animation, la fermeture, la reprise — demande un téléphone.
