# ADR-0053 — Le lecteur descend seul quand la connexion ne suit pas

- **Statut :** accepté. La décision est testée ; **l'enchaînement complet (coupures réelles, puis
  nouvelle session) n'a tourné sur aucun appareil.**
- **Date :** 2026-10-08
- **Portée :** `app/lib/screens/player/playback/adaptive_quality.dart`,
  `app/lib/screens/player/hooks/player_controller_hls.dart` (`_noteStall`, `chooseQuality`),
  `app/lib/screens/player/playback/playback_stats.dart` (`declaredBitrateBps`),
  `app/lib/screens/settings/pages/playback_page.dart`, `app/test/adaptive_quality_test.dart`.
- **Prolonge :** [ADR-0022](0022-echelle-de-transcodage-avec-debits.md) (l'échelle de débits).

## Contexte

L'ADR-0022 a donné au spectateur une échelle de seize débits pour répondre à une ligne qui ne
suit pas. Encore fallait-il qu'il sache que le remède était dans le menu Qualité, et qu'il devine
quel barreau demander. Une lecture qui se coupe toutes les trente secondes restait, pour la
plupart des gens, une lecture cassée.

Le lecteur a pourtant la preuve sous la main. Il garde des minutes d'avance : un tampon vide en
pleine lecture dit que le débit reçu est passé sous celui du film (c'est le raisonnement de
`CachePausePolicy`).

## Décision

1. **Trois coupures en trois minutes, et le lecteur descend d'un barreau.** `AdaptiveQuality` les
   compte. Une coupure seule est un accroc. Celles qui suivent de moins de quinze secondes une
   recherche, une reprise, un changement de piste ou de qualité ne comptent pas : c'est le lecteur
   qui vient de vider son tampon.
2. **Le barreau visé est le premier à 70 % ou moins du débit en cours.** Juste en dessous, la ligne
   ne suivrait pas mieux. En Direct Play, le débit en cours est celui que les pistes annoncent ;
   faute de l'avoir, le barreau natif de la source sert de plafond.
3. **Le lecteur ne remonte jamais de lui-même.** Rien ne dit qu'une ligne qui tient 4 Mbit/s en
   tiendrait 10, et un aller-retour entre deux barreaux serait pire que le plus bas des deux.
4. **Un choix fait dans le menu Qualité l'emporte jusqu'à la fin de la lecture** (`chooseQuality`).
   La lecture suivante repart en Direct Play, comme avant.
5. **L'écran le dit** (« Connexion lente : qualité réduite à 1080p · 4 Mbit/s »), une fois la
   nouvelle session ouverte, pour que l'image moins fine ait une explication.
6. **Un réglage de l'appareil, activé d'office**, dans Réglages → Lecture → Connexion. De
   l'appareil et non du compte : c'est la ligne où il se trouve qui ne suit pas (ADR-0004).
7. **Jamais sur un fichier téléchargé**, ni avant la première image.

## Alternatives écartées

- **Proposer au lieu de faire** (un bouton « Passer à 1080p · 4 Mbit/s »). Il faudrait un bouton
  de plus à atteindre à la télécommande, pendant que l'image est figée. Le réglage et le menu
  laissent la main à qui la veut.
- **Un flux à débit variable** (plusieurs variantes dans la playlist, le moteur choisit). Le
  serveur encoderait plusieurs barreaux à la fois ; sur la machine de production, un seul occupe
  déjà un cœur.
- **Mesurer le débit de la ligne** pour viser juste. Les moteurs ne le donnent pas tous, et la
  moyenne des octets tirés compte aussi les pauses. La règle des 70 % descend en deux pas là où
  une mesure en ferait un.

## Conséquences

- **Une lecture en Direct Play peut ouvrir un transcodage sans qu'on l'ait demandé.** C'est une
  charge pour le serveur, bornée par le plafond de sessions de l'ADR-0033. Un serveur qui refuse
  la session laisse la lecture où elle était.
- Un serveur d'avant l'ADR-0022 ne publie pas d'échelle : rien ne se passe.
- Deux descentes demandent six coupures. Sur une ligne très en dessous du fichier, le spectateur
  en voit donc plusieurs avant que l'image tienne.
- **À vérifier sur un appareil** : que chaque moteur signale bien une coupure par `isBuffering`
  sans mettre `isPlaying` à faux (mpv, ExoPlayer, AetherEngine), et le texte de l'annonce sur TV.
