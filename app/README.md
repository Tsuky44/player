# Onyx — client Flutter

Client Direct Play du serveur média Onyx (`../server`). Une seule base de code
pour macOS, Windows, Android et le web.

## Lancer

```bash
flutter run -d macos    # ou windows, chrome, ou un appareil Android
```

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
