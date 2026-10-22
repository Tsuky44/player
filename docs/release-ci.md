# Publier une version (GitHub Actions)

`.github/workflows/release.yml` produit, en un seul run :

- `Onyx-<version>-android.apk`
- un App Bundle pour Google Play (artefact `store-android` du run, build `STORE_BUILD` — voir
  l'ADR-0046 ; il ne va ni dans la Release ni sur `/api/downloads`)
- `Onyx-<version>-macos.dmg`
- `Onyx-<version>-windows.exe` + `-windows-portable.zip`
- `Onyx-<version>-ios.ipa` (non signé, pour sideloading)
- `Onyx-<version>-tvos.ipa` (Apple TV, non signé — voir l'ADR-0028 ; job en
  `continue-on-error`, une Release peut partir sans lui)
- `Onyx-<version>-webos.ipk` (lanceur des téléviseurs LG, non signé, pour le mode
  développeur — voir l'ADR-0076 et [`docs/webos.md`](webos.md) ; il est joint à la Release
  mais n'apparaît pas sur `/api/downloads`, qui ne connaît pas l'extension `.ipk`)
- le bundle Flutter Web, embarqué dans le binaire Go
- l'image `ghcr.io/tsuky44/playeur-server` taguée `latest`, `v<version>`, `v<majeur.mineur>`
- une GitHub Release portant tous les installateurs

Les installateurs ne sont plus embarqués dans l'image (ADR-0062) : ils ne vivent
que dans la GitHub Release. Un serveur d'une version donnée (`--build-arg
VERSION`, annoncée sur `/api/ping`) télécharge ceux de la Release `v<version>`
à la première demande (`server/releasedl`) ; ils apparaissent dans
**Paramètres → Applications** sans aucune déclaration supplémentaire.

## Déclencher

**Actions → Release → Run workflow**, puis choisir l'incrément :

| Bump | Dernier tag `v1.0.34` → |
|---|---|
| `patch` (défaut) | `v1.0.35` |
| `minor` | `v1.1.0` |
| `major` | `v2.0.0` |

La version est calculée à partir du dernier tag `vX.Y.Z` (tri sémantique), et
le tag est créé par la GitHub Release sur le commit construit : plus besoin de
retenir le dernier numéro ni de pousser un tag à la main. Le champ **version**
permet de forcer un numéro précis ; il est refusé si le tag existe déjà.

Depuis un terminal, avec la CLI GitHub :

```bash
gh workflow run release.yml -f bump=patch
```

### Ne reconstruire que certaines plateformes

Le formulaire **Run workflow** propose une case par plateforme (Android, Windows, macOS,
iOS, Apple TV, LG webOS), toutes cochées par défaut. Un correctif qui ne touche que LG se
publie en décochant les autres : les postes Windows, Android, etc. ne se voient proposer
aucune mise à jour.

Une plateforme décochée n'est pas absente de la Release : le job `publish` reprend
l'installateur de la Release la plus récente qui l'a, **sans le renommer**. La Release
`v1.0.41` porte alors `Onyx-1.0.40-android.apk`. Le serveur lit la version dans le nom
du fichier (`/api/downloads`), et l'app la compare à la sienne : une app Android en
1.0.40 reste à jour. Le ZIP Windows garde sa signature, liée à sa propre version
(ADR-0030). Les fichiers repris sont listés dans le résumé du run et dans la description
de la Release.

Ce qui est toujours reconstruit, quelles que soient les cases : les tests, le bundle web,
l'image Docker et la Release. Le serveur et l'app web (donc les téléviseurs LG, qui
ouvrent l'app web du serveur, ADR-0076) sont à la nouvelle version. C'est aussi l'image
qui fait arriver les installateurs : un serveur ne propose que ceux de la Release de sa
version (ADR-0062), donc sans nouvelle image, aucune mise à jour n'atteindrait les
clients.

Le même mécanisme rattrape un échec Apple TV (job en `continue-on-error`) : l'IPA
précédent est repris au lieu de disparaître de la Release. Le build Play (App Bundle) et
les envois TestFlight suivent la case de leur plateforme.

```bash
gh workflow run release.yml -f bump=patch -f android=false -f windows=false -f macos=false -f ios=false -f tvos=false
```

Un tag poussé (`git push origin v1.0.1`) n'a pas de cases : il reconstruit tout.

Pousser un tag reste possible :

```bash
git tag v1.0.1 && git push origin v1.0.1
```

`app/pubspec.yaml` n'a pas à être modifié : la CI passe `--build-name` (la
version) et `--build-number` (le numéro du run, toujours croissant) à Flutter.
Après une Release lancée depuis l'UI, `git fetch --tags` récupère le tag en
local.

Si un seul job échoue (toolchain Windows capricieuse, par exemple), relancer ce
job depuis l'UI : les autres artefacts sont conservés le temps du run.

## Rapport avec `publish-image.sh`

Le script local ne publie plus que l'image : sans la Release `v<version>`, le
serveur n'a aucun installeur à proposer. Pour une version complète, lancer le
workflow.

## Secrets à configurer

### Signature des mises à jour Windows (indispensable)

Les postes Windows se mettent à jour à partir du ZIP portable, que
`onyx-updater.exe` n'applique que s'il est signé par la clé dont la moitié
publique est compilée dans l'exe (`app/windows/updater/update_public_key.h`,
voir l'ADR-0030). Sans ce secret, le workflow émet un avertissement et publie un
ZIP non signé : les installations existantes le refusent et restent sur leur
version.

| Secret | Valeur |
|---|---|
| `ONYX_UPDATE_SIGNING_KEY` | contenu du fichier produit par `scripts/sign-windows-update.ps1 -NewKey` (clé privée PKCS#8 en base64) |

À conserver hors du dépôt, comme le keystore Android. La perdre oblige à générer
une nouvelle clé, et les versions déjà installées refuseront alors toute mise à
jour signée par elle : il faudra les réinstaller une fois. Pour signer un build
local, poser la même valeur dans la variable d'environnement
`ONYX_UPDATE_SIGNING_KEY` avant `scripts/build-releases.ps1`.

La même clé signe le DMG macOS (`scripts/sign-macos-update.sh`, ADR-0079) : la
signature est rangée dans le DMG, à côté de l'app, et l'app installée la
vérifie avant de se remplacer. Une rotation de la clé change aussi la clé
publique de `app/lib/services/macos_update_signature_io.dart` ; un test vérifie
que les deux restent la même.

### Signature Android (recommandé)

Sans ces secrets le workflow n'échoue pas : il émet un avertissement et signe
l'APK avec une clé de debug. Cet APK s'installe, mais **ne pourra pas mettre à
jour** une version précédente — les runners étant jetables, la clé de debug
change à chaque run, et Android refuse un remplacement signé d'une autre clé.

Générer la clé une fois, et la conserver précieusement : la perdre signifie que
plus aucune mise à jour ne pourra jamais atteindre les installations existantes.

```bash
keytool -genkey -v -keystore onyx-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias onyx
```

Puis, dans **Settings → Secrets and variables → Actions** :

| Secret | Valeur |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i onyx-release.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | mot de passe du keystore |
| `ANDROID_KEY_ALIAS` | `onyx` |
| `ANDROID_KEY_PASSWORD` | mot de passe de la clé |

Pour un build local signé de la même façon, poser `onyx-release.jks` dans
`app/android/` et créer `app/android/key.properties` (tous deux ignorés par
git) :

```properties
storeFile=onyx-release.jks
storePassword=...
keyAlias=onyx
keyPassword=...
```

### ghcr.io

Rien à faire. Le `GITHUB_TOKEN` du run suffit grâce à `permissions: packages:
write` — pas de PAT à créer, contrairement au script local.

## Limites connues

- **DMG non signé / non notarisé.** Gatekeeper bloque au premier lancement
  (clic droit → Ouvrir pour contourner). La notarisation exige un compte Apple
  Developer à 99 $/an. Même situation qu'avec le script local.
- **DMG arm64.** `macos-latest` est un runner Apple Silicon. Les Mac Intel ne
  sont pas couverts sans un job supplémentaire sur `macos-13`.
- **IPA non signé.** Il ne s'installe pas tel quel : Sideloadly ou AltStore
  le resignent avec un identifiant Apple à l'installation. Sans compte
  développeur payant, l'app expire au bout de 7 jours. Un IPA signé (Ad Hoc,
  TestFlight) demanderait un compte Apple Developer, un certificat et un profil
  de provisionnement en secrets — voir `scripts/build-ios-ipa.sh --signed` pour
  le build local.
- **Minutes CI.** Le dépôt est privé : les minutes macOS comptent ×10 et les
  minutes Windows ×2. Un run complet consomme de l'ordre de 150–250 minutes du
  quota mensuel gratuit (2000).
