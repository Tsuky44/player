# onyx_player_apple

Le lecteur d'Onyx sur iPhone, Mac et Apple TV : [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
dans une vue native, derrière un contrat Pigeon. Voir l'[ADR-0038](../../docs/adr/0038-aetherengine-sur-les-appareils-apple.md).

## Organisation

| Chemin | Rôle |
|---|---|
| `pigeons/messages.dart` | Le contrat Dart↔Swift, seule source de vérité. |
| `lib/` | `OnyxApplePlayer` (commandes, flux d'état, de sous-titres et de journal) et `OnyxApplePlayerView` (la vue native). |
| `darwin/onyx_player_apple/` | Le paquet Swift d'iPhone et Mac, et **les seules sources Swift à modifier**. |
| `tvos/` | Le paquet Swift de l'Apple TV. Ses sources sont une copie de `darwin/`. |
| `tool/sync_tvos.dart` | Recopie les sources vers `tvos/` et corrige la garde d'import de Pigeon. |

## Après une modification

```
dart run pigeon --input pigeons/messages.dart   # si le contrat a changé
dart run tool/sync_tvos.dart                    # toujours
```

`app/test/onyx_player_apple_sources_test.dart` échoue tant que la copie tvOS n'est pas à jour.

## Contraintes

- SwiftPM uniquement : AetherEngine n'existe pas en CocoaPods.
- iOS 18, tvOS 18 et macOS 15 au minimum, les planchers d'AetherEngine.
- AetherEngine est sous LGPL-3.0 avec une exception pour les magasins d'applications : une
  modification du moteur lui-même doit être publiée, pas le code de l'app.
