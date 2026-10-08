# ADR-0055 — Pas de Cast ni d'AirPlay tant qu'aucun appareil ne peut les essayer

- **Statut :** accepté. Rien n'est écrit ; cette ADR dit ce qu'il faudra décider le jour où on les
  fait.
- **Date :** 2026-10-08
- **Portée :** l'envoi de la lecture vers un autre écran (Chromecast, AirPlay). Aucun fichier.

## Contexte

Envoyer un film du téléphone vers la télévision est la fonction qu'on attend d'une app vidéo et
qu'Onyx n'a pas. Les deux protocoles ont été regardés.

**AirPlay.** Sur iPhone et Mac, AetherEngine lit par AVPlayer un flux HLS qu'il sert lui-même, sur
l'appareil (ADR-0038). AirPlay vidéo demande à l'Apple TV d'aller chercher le flux : elle
recevrait l'adresse d'un serveur local au téléphone, qu'elle ne peut pas joindre de façon fiable.
Il faudrait soit lui donner un flux du serveur Onyx (une session HLS, comme avant l'ADR-0038),
soit se contenter de la recopie d'écran, que le système offre déjà sans nous.

**Chromecast.** Le récepteur par défaut de Google ne lit pas le MKV, et rien n'y porte le ticket
de lecture que le serveur exige (`server/playbackauth`). Il faut un récepteur à nous, hébergé quelque part et enregistré
auprès de Google, une session HLS du serveur à un débit que l'appareil décode, et un plugin
natif côté Android et iOS. Le serveur doit aussi être joignable depuis le Chromecast, ce qui
n'est pas le cas d'une adresse atteinte par VPN depuis le téléphone.

Les deux sont du code natif (Swift, Kotlin, JavaScript du récepteur). Ce dépôt est écrit sous
Windows : le Swift d'AetherEngine attend déjà sa première compilation complète (ADR-0038), et
aucun Chromecast ni Apple TV n'est branché à la machine de développement.

## Décision

**Ni Cast ni AirPlay vidéo pour l'instant.** Écrire l'un ou l'autre sans pouvoir l'essayer
ajouterait un bouton qui ne marche peut-être pas, sur la fonction où un échec se voit le plus :
devant le téléviseur, avec quelqu'un qui attend.

L'app couvre le même besoin par deux chemins qui existent : elle tourne sur Android TV et sur
Apple TV, et la **reprise sur un autre appareil** (`PlaybackHandoffWatch`) fait passer une lecture
du téléphone à la télévision en la lançant là-bas.

## Ce qu'il faudra trancher le jour où on les fait

- **Qui lit ?** Un flux HLS du serveur dans les deux cas : le récepteur n'ouvre pas le fichier.
  Les capacités déclarées (ADR-0014) sont alors celles du récepteur, pas celles du téléphone.
- **Qui a le droit de lire ?** Un ticket de lecture vaut pour un compte et un média, et c'est le
  client qui le renouvelle. Le téléphone en demande un pour le récepteur : il faut dire qui le
  renouvelle quand le téléphone s'endort.
- **Qui tient la progression ?** Le téléphone devient une télécommande : c'est lui qui rapporte la
  position, ou le serveur la déduit de la session.
- **Le récepteur Chromecast** : où il est hébergé, et s'il peut l'être par le serveur Onyx
  lui-même (il lui faut une adresse HTTPS publique, que la plupart des installations n'ont pas).

## Conséquences

- Quelqu'un qui n'a ni Android TV ni Apple TV n'a pas de moyen de lire sur son téléviseur depuis
  l'app.
- La recopie d'écran du système (AirPlay ou Google Cast depuis les réglages du téléphone) marche
  sans nous, avec ce qu'elle a de limites : l'écran du téléphone reste allumé.
