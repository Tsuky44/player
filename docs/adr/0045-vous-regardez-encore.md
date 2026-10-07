# ADR-0045 — « Vous regardez encore ? »

- **Statut :** accepté. Le Go et le Dart sont testés ; la question n'a pas encore été vue dans une
  vraie lecture, ni essayée à la télécommande sur un téléviseur.
- **Date :** 2026-10-05
- **Portée :** `app/lib/screens/player/playback/still_watching.dart`,
  `app/lib/screens/player/widgets/still_watching_prompt.dart`,
  `app/lib/models/still_watching_settings.dart`, la page de réglages « Lecture »,
  `server/handlers/playback_preferences.go`, la table `user_playback_preferences`.

## Contexte

Un épisode enchaîne sur le suivant au bout de cinq secondes, sans limite. S'endormir devant une
série, c'est la retrouver dix heures plus loin : la progression est perdue, et l'écran, le serveur
et parfois un transcodage ont tourné toute la nuit pour personne. La minuterie de veille répond à
celui qui sait qu'il va s'endormir ; il manquait la réponse pour celui qui ne l'a pas prévu.

## Décision

**Après N épisodes enchaînés sans le moindre geste, le lecteur attend une réponse au lieu de lancer
le suivant.**

- **Ce qui compte, ce sont les enchaînements automatiques**, pas le temps : la question n'est
  posée qu'au moment où le lecteur allait lancer un épisode de lui-même (fin du compte à rebours du
  générique, ou fin du fichier). Elle ne coupe jamais un épisode en cours.
- **Le moindre geste remet le compte à zéro** : touche, télécommande, souris qui bouge, doigt posé,
  touche de casque. L'écoute est à la racine de l'app (`HardwareKeyboard`, routeur de pointeurs),
  pas dans le lecteur : un menu ouvert par-dessus l'image vit dans un autre arbre, et y choisir une
  piste est bien « être là ».
- **Le compte vit hors du lecteur**, comme la minuterie de veille : chaque épisode a son propre
  écran. Il repart de zéro quand on quitte le lecteur.
- **Pas de compte à rebours sur la question.** La lecture est en pause et n'en sort que par
  « Continuer » ou « Quitter » (Retour vaut « Quitter », une touche « lecture » vaut « Continuer »).
  Une question qui se répondrait seule ne protégerait pas celui qui dort.
- **Une plage horaire optionnelle.** Hors de la plage, le compte continue de monter sans rien
  demander : celui qui s'endort à 21 h devant une plage qui commence à 22 h est arrêté au premier
  générique qui tombe dedans. L'heure est celle de l'appareil qui lit — « la nuit » est celle de la
  personne, pas celle du serveur.
- **Désactivé par défaut.** La question ne se pose que si on l'a allumée dans Paramètres →
  Lecture : interrompre une soirée est un choix, pas un comportement qu'une mise à jour impose.
  Une fois allumée, elle propose trois épisodes, toute la journée.
- **En séance « Regarder ensemble » la question n'est pas posée** : d'autres regardent.

### Le réglage appartient au compte

C'est une préférence de la personne, vraie sur tous ses appareils : elle suit l'ADR-0043 (quatre
colonnes, mise à jour partielle, mêmes règles de réconciliation). Les quatre champs
`still_watching_*` partent toujours ensemble, les deux bornes de la plage ne se validant qu'à deux.

Un serveur plus ancien ne renvoie pas ces champs : l'appareil garde alors son réglage local au lieu
de le voir remis aux valeurs par défaut à chaque synchronisation.

## Conséquences

- Rien ne change pour qui n'y touche pas : l'enchaînement reste sans limite tant que le réglage
  n'est pas allumé.
- Le compte ne voit pas la présence, seulement les gestes : quelqu'un d'éveillé et d'immobile est
  interrogé comme quelqu'un qui dort. C'est le prix d'une règle sans capteur.
- Le lecteur web des liens de partage n'enchaîne pas par ce chemin et n'est pas concerné.
- Changer la fenêtre de saisie (bornes à la minute, jours de la semaine) ne demande rien au
  serveur pour les minutes — elles sont déjà stockées ainsi — et une colonne pour les jours.
