# ADR-0043 — Les réglages de lecture suivent le compte

- **Statut :** accepté. Le Go et le Dart sont testés ; la synchronisation n'a pas encore été
  essayée entre deux vrais appareils.
- **Date :** 2026-10-05
- **Portée :** `server/handlers/playback_preferences.go`, la table `user_playback_preferences`,
  `app/lib/services/playback_preferences_storage.dart`, la page de réglages « Lecture ».

## Contexte

Le saut d'intro automatique et la langue audio par défaut vivaient dans les `SharedPreferences` de
chaque appareil. Activer le saut d'intro sur le téléphone ne changeait rien sur le téléviseur : il
fallait refaire chaque réglage sur chaque appareil, au D-pad pour certains. Les playeurs du Player
Studio, eux, étaient déjà sur le compte.

## Décision

**Un réglage qui tient au goût de la personne appartient au compte ; un réglage qui corrige le
matériel appartient à l'appareil.**

| Réglage | Où il vit | Pourquoi |
|---|---|---|
| Saut d'intro automatique | compte | une préférence, vraie partout |
| Langue audio par défaut | compte | idem |
| Liste des playeurs | compte (déjà le cas) | — |
| Playeur actif | appareil (déjà le cas) | une télécommande et un écran tactile n'appellent pas la même interface |
| Décodage matériel, fréquence d'écran | appareil | ADR-0004 : ils contournent un pilote ou un téléviseur précis, et les envoyer ailleurs y casserait une lecture qui marchait |
| Téléchargements, mode TV | appareil | ADR-0027 : c'est l'appareil qui paie le réseau et le disque |

Cette décision **ne contredit pas l'ADR-0004** : elle trace la frontière qu'il laissait implicite.

### Le serveur tient la référence, l'appareil une copie

`GET` et `PUT /api/me/playback-preferences`. La mise à jour est partielle : un appareil n'envoie
que le champ qu'on vient d'y changer, pour ne pas remettre à sa propre valeur un réglage changé
ailleurs entre-temps. Une colonne par réglage plutôt qu'un blob JSON : le serveur valide ce qu'il
range, et un nouveau réglage de compte est une colonne et un champ.

L'appareil garde sa copie locale : le lecteur la lit sans attendre le réseau, et elle sert hors
ligne. Il s'aligne sur le compte à la connexion, au retour du serveur et à l'ouverture de la page
« Lecture ». Il n'y a pas de notification poussée : un appareil resté ouvert voit le changement à
l'un de ces trois moments, pas dans la seconde.

### Trois règles de réconciliation

1. **Ce qui a été changé ici sans atteindre le serveur part d'abord.** Le champ est noté en attente
   *avant* l'envoi, avec le compte auquel il appartient. Un réglage changé dans le métro n'est pas
   écrasé par le compte au retour du réseau.
2. **Un compte qui n'a jamais rien enregistré reçoit les réglages de l'appareil.** Sans cela, la
   mise à jour qui apporte la synchronisation effacerait le réglage de tous ceux qui en avaient un.
   Le serveur le signale par un `updated_at` vide.
3. **Sinon, le compte a raison.**

Une note en attente ne part jamais vers un autre compte : deux personnes d'un même foyer peuvent se
succéder sur un téléviseur.

## Conséquences

- Deux appareils qui changent le **même** réglage hors ligne : le dernier à retrouver le serveur
  gagne. Pas d'horodatage par champ — pour deux interrupteurs, ce serait plus de mécanique que le
  conflit n'en mérite.
- Plusieurs serveurs (ADR-0013) : chaque compte a ses réglages. Passer d'un serveur à l'autre
  applique ceux du compte qu'on rejoint.
- Un visiteur de lien de partage (ADR-0037) n'a pas de compte : il garde les réglages locaux.
- Ajouter un réglage de compte : une migration (colonne), un champ dans
  `models.PlaybackPreferences` et dans `playbackPreferencesUpdate`, un champ dans
  `PlaybackPreferencesStorage`.
