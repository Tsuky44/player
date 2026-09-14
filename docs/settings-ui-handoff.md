# Reprise des paramètres — 14 septembre 2026

## État

La refonte est complète : les six pages manquantes (`admin_devices_page`,
`integrations_page`, `library_page`, `linked_servers_page`, `stats_page`,
`users_page`) sont écrites avec les composants partagés, et l’application
compile (`flutter analyze` sans remarque).

## Présentation à conserver

- `app/lib/screens/settings/settings_screen.dart` : navigation sobre sur fond
  charbon uni, icônes sans pastille, sélection discrète avec accent bleu,
  profil intégré à la barre latérale. Animation de page désactivée lorsque
  le système demande de réduire les animations. Sous 840 px, liste de
  catégories qui ouvre chaque page.
- `app/lib/screens/settings/widgets/settings_ui.dart` : SettingsPage,
  SettingsGroup, SettingsTile, SettingsSwitchTile, SettingsChoiceTile,
  StatTile/StatGrid, SettingsPill. Sous 440 px, les contrôles de ligne passent
  sous le texte, sauf les interrupteurs. Les choix sont des ChoiceChip en Wrap.

## Catégories

Mon espace : Mon compte, Lecture, Serveurs, Cet appareil, Applications.
Administration (selon les droits) : Tableau de bord, Historique, Statistiques,
Utilisateurs, Appareils, Bibliothèque, Métadonnées, Serveurs liés.

Retirés : le banc d’essai ExoPlayer (ADR-0009 réalisé) et l’écran séparé
« Préférences de lecture » (la langue audio est dans la page Lecture, que le
menu du lecteur ouvre désormais).

## Activité, historique, statistiques, appareils

- Le lecteur envoie `POST /api/playing` au démarrage, toutes les 15 s (pause
  comprise) et à l’arrêt. Serveur : `server/handlers/activity.go`.
- Table `playback_history` (migration 7). Les pauses ne comptent pas ; une
  lecture de moins de 30 s est oubliée ; une reprise sur le même appareil dans
  les 5 minutes continue la même ligne.
- Chaque requête porte `X-Onyx-Device` et `X-Onyx-Client` (encodés en
  pourcentage) : `server/handlers/devices.go` les enregistre sur la session.
- Routes admin (`manage_users`) : `/api/admin/activity`, `/history`, `/stats`,
  `/devices`. Infos serveur (`/api/admin/server`) : tout droit
  d’administration. Pour chacun : `/api/me/stats`, `/api/me/devices`.

## Vérification

- `go test ./...` (via Docker `golang:1.21`) : tout passe.
- `flutter test --no-pub test/settings_screen_test.dart
  test/settings_ui_layout_test.dart test/servers_screen_test.dart` : passent.
- Échecs préexistants, sans rapport : `download_manager_test` (séparateurs de
  chemin Windows), `tv_link_host_test` (sockets locales),
  `no_bare_text_field_test` (`glass_chrome.dart`).
- Non vérifié à la main : l’app lancée contre un serveur mis à jour
  (tableau de bord en direct pendant une lecture réelle, TV à la télécommande).
