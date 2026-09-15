# Publier une version (GitHub Actions)

`.github/workflows/release.yml` produit, en un seul run :

- `Onyx-<version>-android.apk`
- `Onyx-<version>-macos.dmg`
- `Onyx-<version>-windows.exe` + `-windows-portable.zip`
- `Onyx-<version>-ios.ipa` (non signé, pour sideloading)
- le bundle Flutter Web, embarqué dans le binaire Go
- l'image `ghcr.io/tsuky44/playeur-server` taguée `latest`, `v<version>`, `v<majeur.mineur>`
- une GitHub Release portant tous les installateurs

Les installateurs sont copiés dans `server/downloads/` avant le build Docker.
`server/handlers/downloads.go` scanne ce dossier au runtime : les liens
apparaissent dans **Paramètres → Applications** sans aucune déclaration
supplémentaire.

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

Le script local reste utilisable pour une publication depuis ce Mac. Il porte un
contournement dont la CI n'a pas besoin : comme Flutter ne cross-compile pas le
desktop, il récupère par `docker pull` les artefacts que l'hôte ne sait pas
produire dans l'image précédente. Dans la CI, les trois plateformes ont chacune
leur runner, donc chaque publication repart d'artefacts frais.

## Secrets à configurer

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
