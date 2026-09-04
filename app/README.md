# Onyx — client Flutter

Client Direct Play du serveur média Onyx (`../server`). Une seule base de code
pour macOS, Windows, Android, iOS et le web.

## Lancer

```bash
flutter run -d macos    # ou windows, chrome, ou un appareil Android / iOS
```

## iOS

Le lecteur y est mpv (`media_kit`), comme sur macOS et Windows — ExoPlayer ne
sort pas d'Android (ADR-0009, ADR-0011). Rien de spécifique côté Dart : c'est
`ios/` qui porte les réglages qui comptent, et ils sont expliqués dans
l'ADR-0011.

Produire un `.ipa` installable sur un iPhone :

```bash
../scripts/build-ios-ipa.sh
```

Le fichier atterrit dans `../dist/ios/`. Il n'est pas signé : c'est Sideloadly
ou AltStore qui le resigne à l'installation, sans compte développeur payant
mais avec une durée de vie de 7 jours. Avec un compte Apple configuré dans le
projet Xcode, `../scripts/build-ios-ipa.sh --signed` produit un `.ipa` signé.

## Repères

- `lib/screens/` — login, shell (accueil, films, séries, demandes), fiches détail, lecteur, Player Studio, réglages.
- `lib/providers/` — état applicatif (Provider).
- `lib/theme/` — `AppColors` et `AppTheme`, la direction « Quiet Premium ».
- `lib/widgets/global/onyx_mark.dart` — la marque Onyx, dessinée en `CustomPainter`.

## Marque

Les sources de la marque vivent dans `../brand` (mark, wordmark vectorisé,
icônes par plateforme). Les icônes d'app se régénèrent avec :

```bash
../brand/generate-icons.sh
```

Attention : « playeur » reste le mot du domaine pour un preset de layout du
Player Studio (« Mes playeurs »). Ce n'est pas un reste de l'ancien nom produit
et il ne faut pas le renommer.
