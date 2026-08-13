# Publier une version (GitHub Actions)

`.github/workflows/release.yml` produit, en un seul run :

- `Onyx-<version>-android.apk`
- `Onyx-<version>-macos.dmg`
- `Onyx-<version>-windows.exe` + `-windows-portable.zip`
- le bundle Flutter Web, embarqué dans le binaire Go
- l'image `ghcr.io/tsuky44/playeur-server` taguée `latest`, `v<version>`, `v<majeur.mineur>`
- une GitHub Release portant les quatre installateurs

Les installateurs sont copiés dans `server/downloads/` avant le build Docker.
`server/handlers/downloads.go` scanne ce dossier au runtime : les liens
apparaissent dans **Paramètres → Applications** sans aucune déclaration
supplémentaire.

## Déclencher

```bash
git tag v1.0.1 && git push origin v1.0.1
```

Ou l'onglet **Actions → Release → Run workflow**, en saisissant la version.
Le bouton n'apparaît qu'une fois le workflow présent sur la branche par défaut.

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
- **Pas d'`.ipa`.** `app/ios/` n'existe pas. Au-delà du CI, il faudrait
  conditionner `window_manager` (pas de support iOS), valider `media_kit` sur
  iOS, et disposer d'un compte Apple Developer : hors App Store, la
  distribution est limitée à l'Ad Hoc (100 appareils, UDID à enregistrer) ou au
  sideloading.
- **Minutes CI.** Le dépôt est privé : les minutes macOS comptent ×10 et les
  minutes Windows ×2. Un run complet consomme de l'ordre de 150–250 minutes du
  quota mensuel gratuit (2000).
