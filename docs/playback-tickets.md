# Tickets temporaires de lecture

Implémentation locale de la phase 1 de la [roadmap](roadmap-lecture.md). Les tests automatiques passent ; aucun déploiement ni test manuel de cette version n'a été effectué sur le serveur externe.

## Contrat

Le client authentifié crée une autorisation avec `POST /api/playback/tickets`, corps `{"media_id":42}`. La réponse contient `ticket`, `expires_at` et `renew_after_seconds`. Le ticket est un secret aléatoire de 256 bits encodé en base64url, limité à un utilisateur et un média. Le serveur conserve uniquement son hash SHA-256 et ses métadonnées dans un store mémoire borné : 32 tickets par utilisateur, 4 096 au total.

Le ticket expire après 15 minutes. Un `PUT /api/playback/tickets`, authentifié par le compte émetteur et portant le ticket dans le corps JSON, renouvelle son échéance. Le client le fait toutes les cinq minutes. Lire un segment actualise la dernière activité mais ne repousse pas l'expiration. Un `DELETE` authentifié sur la même route révoque le ticket ; ni renouvellement ni révocation ne peuvent agir sur le ticket d'un autre utilisateur. Un ticket expiré ou révoqué ne peut pas être ressuscité.

Le paramètre `ticket` est requis sur `/stream`, les routes de sous-titres et toutes les routes HLS, y compris création et suppression d'une session. Les requêtes Range restent prises en charge. Un transfert direct déjà ouvert cesse également d'écrire au prochain bloc si son ticket est révoqué ou expire ; les octets déjà reçus par le client ne peuvent évidemment pas être retirés.

Chaque session HLS conserve le hash de son ticket. Un autre ticket, même valide pour le même média, ne permet pas de consulter ou de supprimer cette session. Les playlists master et enfants ajoutent le ticket à toutes leurs références : vidéos, pistes audio et initialisations fMP4. Une référence externe, absolue, remontant un dossier ou mal formée est refusée. Les ressources protégées ne sont pas stockées dans un cache HTTP partagé.

Le client possède une autorisation distincte par lecture ou téléchargement. Le renouvellement et la révocation restent attachés au serveur et au compte émetteurs après un changement de serveur actif. Les appels médias utilisent le ticket et ne transmettent pas le Bearer du compte actif. Les fichiers hors ligne déjà téléchargés restent lisibles sans ticket ni connexion.

À la fermeture normale, le lecteur demande la destruction de sa session HLS puis révoque son autorisation. Une création HLS annulée pendant le démarrage est nettoyée côté serveur. Le reaper HLS vérifie aussi la validité du ticket toutes les 30 secondes, et supprime les sessions abandonnées ; le store de tickets est purgé chaque minute. Un redémarrage du serveur invalide tous les tickets puisqu'ils ne sont pas persistés : relancer la lecture recrée une autorisation. Un appareil suspendu au-delà de l'échéance doit également relancer sa lecture.

## Migration

| Client | Serveur | Comportement |
| --- | --- | --- |
| Nouveau | Nouveau | Tickets obligatoires pour tous les médias |
| Nouveau | Ancien | Anciennes URL seulement après confirmation par `/api/ping` |
| Ancien | Nouveau | Lecture refusée : mettre le client à jour |
| Ancien | Ancien | Ancien comportement, flux non protégés |

Le nouveau serveur annonce `playback_ticket_version: 1` sur `/api/ping`. Le client n'autorise la compatibilité ancienne que si la route de tickets répond 404/405 **et** si un ping valide de l'ancien serveur n'annonce aucune version de tickets. Un média absent sur un nouveau serveur, un refus d'authentification, un timeout ou une erreur serveur ne déclenchent jamais une tentative d'URL publique.

Ordre de déploiement : distribuer les nouveaux clients natifs, puis mettre à jour le serveur avec le nouveau bundle web. Le script de publication et la CI existants sont décrits dans [release-ci.md](release-ci.md). Ne pas publier un serveur sécurisé avec un ancien bundle web ou des installateurs récupérés d'une ancienne image. Aucun mode de secours ouvrant les flux sans ticket n'est ajouté au nouveau serveur.

Les reverse proxies doivent conserver le paramètre de requête jusqu'au backend, utiliser HTTPS pour les accès distants, et omettre les query strings des journaux de médias (par exemple `$uri` à la place de `$request_uri` dans un journal Nginx). Purger les anciennes entrées de cache publiques de `/stream` et des sous-titres si un proxy les conservait. La journalisation applicative des erreurs de lecture masque les URL, tickets et Bearer ; les journaux d'un proxy externe ne sont pas configurés par ce dépôt.

## Validation locale

- `cd server && go test ./...` : succès.
- `cd server && go test -race ./playbackauth ./streaming ./handlers` : succès.
- `cd app && flutter test --no-pub` : 338 tests réussis dans l'état de travail testé.
- `cd app && flutter analyze --no-pub` : aucune erreur ni avertissement d'analyse.
- `cd app && flutter build web --no-pub` : build JavaScript réussi ; le diagnostic optionnel Wasm signale les dépendances non compatibles existantes.

Les tests couvrent expiration, renouvellement, révocation, isolation entre utilisateurs/médias/sessions, limites du store, arrêt d'une réponse déjà ouverte, HTTP Range, sous-titres, références HLS, ancien serveur, changement de serveur actif et masquage des secrets.

## Validation restante, avec accord préalable

Sur une instance externe de test mise à jour et un client reconstruit : ouverture Direct Play, seek court et long, changement de qualité, piste audio et sous-titres ; lecture maintenue au-delà de 15 minutes pour vérifier le renouvellement ; fermeture puis refus de l'ancienne URL ; téléchargement/reprise et lecture hors ligne. Répéter avec mpv, Android et web. Les validations sur ces moteurs et la configuration du proxy restent distinctes des tests automatiques.
