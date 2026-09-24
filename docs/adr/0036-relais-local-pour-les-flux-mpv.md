# ADR-0036 — Un relais local pour que mpv ne résolve plus les noms

- **Statut :** accepté. En place et testé, jusqu'à la chaîne réelle libmpv → relais → serveur
  derrière Cloudflare (premier démultiplexeur à +98 ms).
- **Date :** 2026-09-24
- **Portée :** l'ouverture des flux par mpv sur desktop
  (`app/lib/screens/player/playback/mpv_playback_session.dart`), le relais
  (`app/lib/services/stream_proxy_io.dart`) et le carnet d'adresses des serveurs
  (`app/lib/services/dns_warmup_io.dart`). Complète l'ADR-0034.

## Contexte

Sous Windows, un serveur DNS mort sur une carte réseau (la box, un adaptateur VPN) fait attendre
toute résolution hors cache 11 s. Le lecteur la payait devant la première image : 11,4 s de
silence entre le hook `on_load` et le premier démultiplexeur, reproduites dans la libmpv seule.

Garder le cache du système au chaud n'a pas suffi. Ses entrées IPv4 et IPv6 expirent chacune
toutes les cinq minutes. Une résolution servie par le cache ne les renouvelle pas, et une requête
qui le contourne (`DNS_QUERY_BYPASS_CACHE`) ne les renouvelle pas non plus : c'est mesuré. Chaque
expiration rouvre une fenêtre où la lecture repaie les 11 s, et un démarrage à 11,6 s est revenu
malgré le pré-chauffage.

Les pistes par options mpv ont été essayées sur la libmpv de l'app et écartées :

- La libmpv ouvre ses flux avec libcurl, et mpv n'expose pas `CURLOPT_RESOLVE`.
- Mettre l'adresse IP dans l'URL fait échouer le TLS : Cloudflare refuse une poignée de main sans
  le nom (SNI).
- Repasser sur le client HTTP de FFmpeg (`curl-enabled=no`) ne marche pas mieux : `verifyhost` ne
  fixe pas le SNI quand l'URL porte une adresse.

## Décision

- L'app garde la dernière adresse résolue de chaque serveur connu. Elle reste valable jusqu'à la
  réponse suivante, même expirée côté système.
- Sur desktop, mpv ouvre ses flux HTTPS par `http-proxy`, qui pointe vers un relais `CONNECT` de
  l'app, sur 127.0.0.1 uniquement. libcurl ne résout alors rien : il demande `CONNECT hôte:443` et
  mène le TLS de bout en bout. Le relais se connecte à l'adresse gardée, avec le nom en dernier
  recours, puis recopie les octets chiffrés.
- En HTTP, sur mobile et sur le web, rien ne change.

## Conséquences

- Le démarrage ne dépend plus du DNS du poste pour un serveur déjà résolu une fois.
- Tout le flux vidéo traverse le processus de l'app. La copie se fait avec contre-pression
  (`addStream`), la mémoire reste bornée, et rien n'est déchiffré.
- Si le relais ne démarre pas, mpv résout lui-même, comme avant.
- Une adresse périmée qui ne répond plus coûte trois secondes avant le repli sur le nom.
- Découvert en chemin : avec libcurl, les options `stream-lavf-o` de reconnexion
  (`reconnect=1…`) ne s'appliquent pas aux flux HTTP. C'est à revoir séparément.
