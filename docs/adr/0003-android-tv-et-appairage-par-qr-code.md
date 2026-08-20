# ADR-0003 — Android TV : pilotage à la télécommande et appairage par QR code

- **Statut :** accepté
- **Date :** 2026-08-20
- **Portée :** l'APK Android (installation sur téléviseur, navigation D-pad) et le serveur
  (appairage d'appareil). Le lecteur externe (Chromecast, DLNA) est hors périmètre.

## Contexte

L'APK s'installait sur téléphone et sur tablette. Sur un téléviseur Android il ne s'installait
pas du tout : le manifeste déclarait implicitement un écran tactile obligatoire, et n'exposait
aucune catégorie `LEANBACK_LAUNCHER`, donc aucune icône sur l'écran d'accueil de la TV.

Même installé de force, l'app restait inutilisable :

- Les vignettes du catalogue sont des `InkWell` dans des layouts sur mesure. Elles acceptent le
  clic et le survol ; rien dans cette pile ne demande le focus, donc la croix directionnelle
  n'atteignait aucune affiche.
- Flutter choisit son mode de surbrillance d'après la dernière entrée observée. Sur Android il
  démarre en `touch`, et dans ce mode les widgets Material ne peignent aucun état de focus :
  l'utilisateur déplaçait la croix et rien ne bougeait à l'écran.
- L'écran de connexion demandait une adresse de serveur, un identifiant et un mot de passe. Les
  saisir au D-pad sur un clavier virtuel est la première chose que fait un nouvel utilisateur, et
  c'est une minute de chasse au caractère.

## Décision

### 1. Un seul APK, pas une variante TV

Le manifeste déclare `android.software.leanback` et `android.hardware.touchscreen` en
`required="false"`, et ajoute `LEANBACK_LAUNCHER` à l'intent-filter existant. Le même artefact
s'installe donc sur téléphone et sur téléviseur.

L'alternative — une saveur Gradle `tv` — aurait doublé la matrice de publication (CI, signature,
page de téléchargement, mise à jour intégrée) pour un manifeste qui diffère de trois lignes.

`android:banner` est requis pour figurer sur la rangée d'accueil d'Android TV ; il est fourni en
vector drawable plutôt qu'en cinq PNG de densité.

### 2. Le mode TV est un état global, résolu avant la première frame

`TvMode` interroge le natif (`UiModeManager`, `FEATURE_LEANBACK`, absence d'écran tactile) et
publie un booléen dans l'arbre via `TvScope`. Il est résolu dans `main()` avant `runApp` : l'écran
de connexion diffère entièrement entre un téléphone et une TV, et basculer après coup afficherait
le formulaire de mot de passe pendant un instant à chaque démarrage.

Un réglage à trois états (`auto` / `activé` / `désactivé`) permet de forcer les deux sens. La
détection se trompe dans les deux directions : un boîtier sans marque qui n'annonce jamais
leanback, et une tablette sur dock qui l'annonce.

### 3. Le focus, pas une seconde arborescence de navigation

Rien ne duplique les écrans. Trois mécanismes rendent l'existant atteignable :

- `TvFocusable` enveloppe les vignettes maison, prend le focus, dessine la surbrillance et
  fait défiler le conteneur pour rester visible. **Le widget enveloppé perd son propre focus**
  (`canRequestFocus: false` sur l'`InkWell` interne) — sinon chaque affiche compterait deux arrêts
  et la télécommande demanderait deux appuis pour traverser une carte.
- Les boutons Material sont laissés tels quels : ils sont déjà focusables. Le thème leur ajoute un
  contour d'accentuation à 2,5 px, parce que le lavis à 10 % de Material se lit à bout de bras sur
  un téléphone et pas depuis un canapé.
- `select` (KEYCODE_DPAD_CENTER) et `gameButtonA` sont ajoutés aux raccourcis de l'application, à
  côté de `Enter`. Tout ce qui était activable au clavier devient activable à la télécommande,
  sans qu'aucun widget n'ait à le savoir.

`FocusHighlightStrategy.alwaysTraditional` est forcé en mode TV, sans quoi rien ne se peint.

Les onglets masqués de l'`IndexedStack` du shell sont enveloppés dans `ExcludeFocus` : le parcours
du focus lit l'arbre de widgets, pas ce qui est à l'écran, et sans cela la croix se promenait dans
les affiches d'un onglet invisible.

### 4. Dans le lecteur, les flèches ont deux métiers

Une télécommande a quatre touches de direction et deux besoins : parcourir le film, et parcourir
la barre de contrôle. Le départage se fait au focus — le lecteur le détient par défaut, donc les
flèches naviguent dans le film ; OK donne le focus à la barre, Retour le rend. C'est la seule
règle à retenir, et elle n'ajoute aucun mode caché.

### 5. Connexion par appairage, pas par mot de passe

La TV n'ouvre pas de formulaire : elle ouvre un appairage, affiche le code court en QR, et
attend qu'un téléphone déjà connecté l'approuve. La forme est celle du device flow OAuth
(RFC 8628) moins ce qui suppose un serveur d'autorisation : `start` → `poll` → `approve`.

- `start` et `poll` sont **non authentifiés** — l'appelant est un téléviseur sans compte. Ils ne
  manipulent que des chaînes aléatoires, et rien n'est émis tant qu'un utilisateur connecté n'a
  pas approuvé.
- `approve` s'exécute **sous l'identité de l'appelant**. C'est ce qui garantit que la TV hérite
  exactement du compte qui a appuyé sur le bouton, et d'aucun autre.
- La session est créée dans la même transaction que l'approbation : une session que personne ne
  peut réclamer serait un identifiant en fuite, et une approbation sans session laisserait le
  téléviseur en attente pour toujours.
- La récupération consomme l'appairage. Un `device_code` qui resterait réclamable serait un
  identifiant posé dans une table en attente d'être rejoué.

Le code court fait 8 caractères tirés d'un alphabet de 32 symboles sans `I`, `O`, `0` ni `1` : il
est lu de loin sur un écran et retapé sur un téléphone. 2^40 sur une fenêtre de cinq minutes rend
la recherche exhaustive sans objet, ce qui évite d'ajouter une limitation de débit dédiée.

Le QR encode `<serveur>/?tv=CODE`, composé côté client comme le lien d'invitation : derrière un
proxy ou un tunnel, le serveur ignore sa propre adresse publique, et le téléphone doit joindre
celle que la TV a effectivement utilisée. L'appareil photo natif suffit — aucune dépendance
caméra n'est ajoutée à l'app.

## Conséquences

- Le formulaire mot de passe reste accessible depuis l'écran TV, à un bouton. Un foyer dont le
  seul appareil est le téléviseur doit pouvoir entrer, et le tout premier compte d'un serveur
  vierge n'a personne pour l'approuver.
- Une session approuvée mais jamais récupérée est balayée par le reaper d'appairages, cinq minutes
  après expiration, au lieu d'attendre les quatre-vingt-dix jours d'inactivité des sessions.
- L'écran d'appairage côté téléphone est le même quel qu'en soit le chemin d'accès (QR scanné ou
  code tapé depuis le menu compte) : les deux se terminent sur la même décision.
- La navigation D-pad est active sur toutes les plateformes, pas seulement sur TV — un utilisateur
  clavier sur desktop en hérite. Seuls le zoom au focus et la prise de focus automatique sont
  réservés au mode TV, où ils ne concurrencent pas le survol souris.
