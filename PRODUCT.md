# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Utilisateur principal : propriétaire / foyer d’un serveur multimédia privé self-hosted. Situation typique : parcourir une bibliothèque personnelle (films, séries), reprendre une lecture, lancer le Direct Play, et éventuellement demander un média manquant. Usage fréquent sur desktop macOS (fenêtre native, title bar custom) et sur mobile ; TV possible via Flutter mais non confirmé comme cible prioritaire de cette passe.

## Product Purpose

Onyx est le client Flutter d’un serveur média léger (Go, Direct Play 100 %). Il remplace l’expérience Emby/Plex côté lecture et découverte pour une bibliothèque personnelle : authentification, accueil (reprendre / récents), catalogues films & séries, fiches détail, demandes de médias, préférences de lecture, lecteur vidéo (media_kit/mpv) et studio de layout des contrôles.

Succès = trouver rapidement un titre, le lire sans friction (seek, audio, sous-titres, reprise), et que l’UI reste claire sur desktop large et mobile étroit — sans casser aucune fonctionnalité existante.

## Positioning

Client Direct Play pur branché sur un backend Go ultra-léger : zéro transcodage côté serveur, décodage client via mpv/media_kit, progression heartbeat, et chrome lecteur personnalisable (Player Studio). Différence clé vs Emby/Plex cloud : contrôle total, empreinte serveur minimale, expérience cinéma privée.

## Operating Context

- Shell principal : Accueil · Films · Séries · Demandes (nav desktop glass header / bottom nav mobile).
- Flux lecture : fiche → PlayerScreen (HUD, scrubber, audio/subs, épisodes, skip intro, next episode, settings).
- Player Studio : édition de layout des contrôles.
- Auth : login / session token sécurisé.
- Backend API locale ou self-hosted (Bearer token ; stream Range public pour compat players).

## Capabilities and Constraints

**Confirmé utilisable et à préserver :**
- Auth, home (continue watching, recent movies/shows, hero), catalogues films/séries, détail film/série/personne/collection, recherche catalogue, demandes de médias, préférences de lecture, lecteur (play/pause, seek, volume, fit, audio, sous-titres, épisodes, skip intro, next episode, media keys desktop), Player Studio (layout drag/edit), états vides / erreurs / progression.

**Contraintes techniques :**
- Flutter + Provider + Material 3 ; thème sombre actuel.
- media_kit / mpv pour la lecture.
- Desktop : window_manager, caption bar optionnelle.
- redesign UI uniquement dans `app/` (Flutter) — MediaHub hors scope (décision utilisateur 2026-07-26).

**Ouvert :**
- Priorité TV/10-foot non confirmée pour cette passe.
- Nom d’affichage produit : « Onyx » (title MaterialApp).

## Brand Commitments

- Nom produit : Onyx. Marque et déclinaisons dans `brand/` (mark, wordmark vectorisé, icônes).
- Direction visuelle documentée dans `design.md` (« Cinematic Glass ») : immersion atmosphérique, glass, charcoal, accent bleu type focus — à traiter comme intention de world, pas forcément comme implémentation actuelle (le code utilise encore Inter + rouge Netflix `#E50914`).
- Carte blanche design accordée par l’utilisateur pour cette passe, sous réserve de garder toutes les fonctionnalités utilisables.

## Evidence on Hand

- Spec produit : `project.md`, `README.md`.
- Intention visuelle : `design.md` (Cinematic Glass).
- Implémentation UI : `app/lib/` (theme, shell, home, library, player, player_studio, requests, auth, widgets glass).
- Pas de testimonials / marketing externes à inventer.

## Product Principles

1. Le contenu est le héros ; le chrome s’efface pendant la lecture.
2. Direct Play et contrôles essentiels restent toujours accessibles en un geste.
3. Densité et scanabilité catalogue > décoration.
4. Une seule identité visuelle cohérente entre shell, fiches et lecteur.
5. Aucune fonctionnalité existante ne peut être retirée ou rendue inutilisable par le redesign.

## Accessibility & Inclusion

Pas de standard formel imposé. Minimum attendu : contraste lisible en dark, cibles tactiles ≥ 44px sur mobile, focus/clavier utilisable sur desktop, respect de `prefers-reduced-motion` quand des animations sont ajoutées.
