# ADR-0033 — Des sessions HLS bornées : nombre, disque, durée de vie

- **Statut :** accepté. En place et testé, jusqu'au binaire réel pour l'arrêt propre et le
  nettoyage au démarrage.
- **Date :** 2026-09-23
- **Portée :** les sessions de transcodage (`server/streaming/workspace.go`, `manager.go`,
  `session.go`, `handler.go`), l'arrêt du serveur (`server/main.go`) et le choix de rouvrir une
  session pour reculer côté client (`app/lib/screens/player/playback/hls_retain_window.dart`).

## Contexte

Rien ne bornait les ressources d'une session HLS :

- **Leur nombre.** Chaque `/start` lançait un FFmpeg de plus. Un saut hors de la session, un
  changement de qualité ou d'incrustation en ouvrait une nouvelle sur le même ticket. L'ancienne
  ne s'arrêtait que si le client la détruisait, et sinon au bout de cinq minutes d'inactivité.
- **Leur disque.** Une session gardait tous ses segments jusqu'à sa fin. Une recopie de remux à
  30 Mbit/s écrit plus de 13 Go par heure, dans le dossier temporaire du système, que la base et
  le système partagent souvent.
- **Leur fin.** Le processus s'arrêtait sur le signal sans rien fermer. Les FFmpeg lui survivaient,
  et leurs dossiers restaient dans le dossier temporaire, où plus personne ne les reconnaissait.

## Décision

- **Une seule session par ticket.** Quand une nouvelle session démarre, les autres du même ticket
  sont marquées remplacées et arrêtées trente secondes plus tard, le temps que le client ouvre la
  nouvelle. Le client peut toujours les détruire plus tôt.
- **Un plafond global** (`MAX_TRANSCODES`, par défaut la moitié des cœurs et au moins 4) répond
  503 avec `Retry-After`. Il ne compte ni les sessions remplacées ni celles du ticket qui demande
  une nouvelle session : un changement de qualité au plafond n'est pas refusé.
- **Un espace de travail à part** (`HLS_DIR`, par défaut `onyx-hls` dans le dossier temporaire).
  Les dossiers de session qu'on y trouve au démarrage sont forcément orphelins et sont effacés, et
  seulement eux. **Une session ne s'ouvre pas** s'il reste moins de `HLS_MIN_FREE_MB` (2 Go).
- **La purge des vieux segments est optionnelle, activée par le client.** Aujourd'hui, un client
  considère que tout ce qui est derrière lui dans la session reste disponible. Effacer des segments
  casserait donc le retour en arrière des applications déjà installées. Un client qui envoie
  `purge=1` s'engage à rouvrir une session pour reculer au-delà de la fenêtre annoncée
  (`retain_seconds`, 30 minutes par défaut derrière le dernier segment demandé). Le serveur efface
  alors le reste, dans toutes les séries de segments. Sans `purge=1`, rien n'est effacé.
- **Arrêt propre.** Sur SIGINT ou SIGTERM, les sessions et les aperçus sont arrêtés en parallèle,
  puis le serveur HTTP dispose de cinq secondes pour finir. L'arrêt d'un conteneur en laisse dix
  avant de tout tuer.

## Conséquences

- Un client qui recule au-delà de la fenêtre paie une nouvelle session, comme pour un saut en
  avant lointain. La marge d'une minute côté client couvre l'écart entre ce que le lecteur annonce
  en tampon et ce qu'il a réellement demandé.
- Deux lectures sur le même ticket ne peuvent plus coexister, ce qu'aucun client ne fait.
- Le plafond par défaut est un choix prudent. Une machine avec encodeur matériel peut le relever.
