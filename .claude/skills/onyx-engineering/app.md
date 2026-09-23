# Logique de l'app Flutter

Package `onyx` dans `app/`. L'état passe par `provider` (`ChangeNotifier`) et le réseau par `dio`. Les cibles sont Android, Android TV, iOS, tvOS (flutter-tvos), macOS, Windows et le web.

## Couches

Les dépendances vont dans un seul sens : **widget → provider → service → serveur**.

| Dossier | Rôle |
|---|---|
| `models/` | Données simples + `fromJson`. Pas d'I/O. |
| `services/` | I/O et intégrations : `ApiClient`, téléchargements, stockage, découverte, mises à jour, journal. |
| `providers/` | État d'un domaine exposé à l'UI (`HomeProvider`, `LibraryProvider`…). |
| `screens/<fonction>/` | Un écran, ses `widgets/` privés et ses `hooks/` (contrôleurs sans UI). |
| `widgets/global/` | Composants partagés par plusieurs écrans. |
| `tv/`, `theme/`, `utils/`, `navigation/` | Infrastructure transverse. |

- Un widget n'appelle jamais `Dio` directement : il passe par un provider ou un service.
- Un contrôleur d'écran (`use_player_controller.dart`, `use_studio_controller.dart`) orchestre, et les widgets qu'il pilote restent passifs : ils prennent des valeurs et des callbacks.
- Un nouvel appel au serveur devient une méthode typée de `ApiClient` qui renvoie un modèle. `api_client.dart` est un fichier-dieu : regroupe les nouveaux appels d'un même domaine dans un fichier dédié plutôt que de le faire grossir.

## Providers

Le modèle à suivre est `LibraryProvider` :

- **Compteur de génération** par chargement (`_moviesRequest++`). Chaque réponse compare sa génération avant d'écrire, pour que la réponse d'une requête obsolète ne remplace pas un état plus récent. `dispose()` incrémente tous les compteurs.
- **`reset()` au changement de serveur** : vide tous les caches du serveur précédent, remet les drapeaux à zéro et relance les chargements des onglets restés montés.
- ***Stale-while-revalidate*** : les caches par clé (`_seasonsByShow`…) permettent de peindre tout de suite au retour sur un écran, puis de revalider en arrière-plan.
- `isLoadingX` et `errorMessage` sont exposés en lecture seule. `errorMessage` est une phrase française destinée à l'utilisateur.
- `notifyListeners()` n'est appelé qu'après un vrai changement d'état.

## Multi-serveur

Plusieurs comptes coexistent (ADR-0013, ADR-0017) : `ServerRegistry`, `ApiClient.pinToAccount`, comptes liés. Toute donnée mise en cache (mémoire, disque, image) est **indexée par serveur ou par compte**, ou bien vidée dans `reset()`. Les tests `server_switch_catalog_test.dart` et `multi_server_session_test.dart` couvrent ce contrat, et un nouveau cache s'y ajoute.

## Plateformes

- Pour du code spécifique au web ou au natif, on utilise un **trio d'imports conditionnels** : `x.dart` (interface et export conditionnel), `x_io.dart` et `x_web.dart` (voir `download_manager*`, `tv_link_host*`, `app_updater*`). `dart:io` ne s'importe jamais hors d'un fichier `_io`.
- Les différences entre plateformes natives passent par `utils/app_platform.dart` et `tv/tv_mode.dart`, jamais par un `Platform.isX` dispersé dans un écran.
- **Lecture** : chaque moteur implémente `PlaybackSession` (`abstract interface class`, dans `screens/player/playback/playback_session.dart`) : mpv/media_kit, ExoPlayer (ADR-0009), AVPlayer sur tvOS (ADR-0028). Une capacité de lecture nouvelle s'ajoute à l'interface puis à chaque moteur. Le lecteur ne teste pas le moteur en cours d'exécution.
- Les capacités de décodage sont déclarées par le client (ADR-0014, `playback_capabilities.dart`), et c'est le serveur qui décide Direct Play ou HLS.
- Hors ligne : l'app démarre sans réseau. On teste la joignabilité sur `GET /api/ping` (ADR-0010 §6). La présence d'un réseau ne prouve pas que ce serveur est joignable.

## Journal

`ClientLog` (ADR-0026) détourne `debugPrint` et `FlutterError.onError`. Journalise avec `debugPrint('…')` et les erreurs avec `ClientLog.error('…')`, qui partent dans le journal exportable. Un `print` nu n'y arrive pas.

## Tests

- Les tests sont dans `app/test/`, un fichier par règle ou par composant, nommé d'après le comportement (`seek_resume_test.dart`, `download_network_gate_test.dart`).
- Les doublures partagées sont dans `test/test_doubles.dart` (un `Registry` avec deux comptes, un `Adapter` Dio). Étends-les plutôt que de recréer une doublure ailleurs.
- Une logique extraite dans une fonction ou une classe pure se teste sans widget. Les tests de widget couvrent le contrat visible : focus TV, mise en page, états.
- `ClientLog.resetForTest()` et les autres points d'entrée `ForTest` existent pour remettre à zéro un état global. Ajoute-en un à tout nouveau singleton.
