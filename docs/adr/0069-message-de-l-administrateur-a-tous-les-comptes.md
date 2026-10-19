# ADR-0069 — Le message de l'administrateur, montré une fois à chaque compte

- **Statut :** accepté
- **Date :** 2026-10-16
- **Portée :** le serveur (`server/handlers/announcements.go`, `server/models/announcement.go`,
  migration 27, capacité `announcements` dans `server/handlers/ping.go`, `contract/announcement*.json`)
  et l'app (`app/lib/screens/settings/pages/announcement_page.dart`,
  `app/lib/widgets/global/announcement_dialog.dart`, `app/lib/screens/shell/pending_announcement.dart`,
  `app/lib/services/api/announcements.dart`).

## Contexte

L'administrateur d'un serveur n'avait aucun moyen de prévenir ceux qui s'en servent : une
maintenance, une nouveauté, un changement de lien. Il voulait écrire un message depuis les
paramètres et que chacun le voie en grand la prochaine fois qu'il ouvre l'app.

## Décision

1. **Un seul message à la fois, le plus récent.** Publier remplace le précédent ; la table
   `announcements` ne garde que la dernière ligne. `AUTOINCREMENT` garantit qu'un identifiant
   ne sert jamais deux fois : un message publié après une suppression passe toujours devant ce
   qu'un compte a déjà fermé.
2. **Le serveur tient « vu » par compte**, dans `users.seen_announcement_id`. Fermé sur un
   téléphone, le message ne revient pas sur la télévision. La marque ne recule jamais (`MAX`) :
   un appareil en retard ne remontre pas l'annonce.
3. **Republier remontre à tous**, même un texte identique : c'est un nouveau message. L'auteur,
   lui, ne le reçoit pas.
4. **`manage_settings` pour écrire** (`GET/PUT/DELETE /api/announcement`), n'importe quel compte
   pour lire et fermer le sien (`GET /api/me/announcement`, `POST /api/me/announcement/seen`).
5. **L'app demande à chaque ouverture de compte** (lancement, bascule de serveur), après la
   présentation de l'interface et une fois l'accueil chargé, jamais par-dessus. La fenêtre ne se
   ferme que par son bouton, qui a le focus pour la télécommande. La marque n'est posée qu'après
   fermeture : un message qui n'a pas pu s'afficher (hors ligne, écran démonté) revient au
   lancement suivant.
6. **La capacité `announcements`** sur `/api/ping` évite d'appeler la route sur un serveur plus
   ancien (ADR-0051).

## Alternatives écartées

- **Le « vu » sur l'appareil** (SharedPreferences). Le même compte reverrait le message sur
  chacun de ses appareils, et l'app aurait à comparer elle-même : c'est au serveur de décider.
- **Une notification système.** Elle ne s'affiche pas « en grand », dépend des permissions de
  chaque plateforme, et n'existe pas sur toutes (tvOS, web).
- **Un historique de messages.** Rien ne le demande ; un seul message suffit à prévenir.

## Conséquences

- Une app restée ouverte (télévision en veille, ordinateur) ne voit le message qu'à sa
  prochaine ouverture ou bascule de compte : la question n'est pas reposée au retour au premier
  plan.
- Avec plusieurs serveurs (ADR-0013), seul le serveur du compte actif est interrogé ; le message
  d'un autre serveur s'affiche quand on bascule dessus.
