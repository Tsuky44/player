# ADR-0030 — Les mises à jour Windows passent par un programme maison, pas par l'installeur

- **Statut :** accepté. Le programme, la signature et le service sont en place. Le chemin
  portable (dossier inscriptible, sans service) est vérifié de bout en bout ; le chemin par le
  service reste à valider sur une vraie installation.
- **Date :** 2026-09-23
- **Portée :** la mise à jour automatique sous Windows (`app/windows/updater/`,
  `app/lib/services/app_updater_io.dart`), l'installeur (`app/installer.iss`) et la publication
  (`scripts/sign-windows-update.ps1`, `.github/workflows/release.yml`). macOS et Android ne
  changent pas.

## Contexte

L'app se mettait à jour en relançant l'installeur Inno en silencieux depuis un script `.cmd`
généré. Trois défauts :

- **Deux consoles restaient ouvertes.** `start` exécute un fichier batch avec `cmd /K`, qui
  garde la fenêtre ouverte une fois le script terminé. L'app relancée depuis cette console s'y
  rattachait (le runner Flutter appelle `AttachConsole(ATTACH_PARENT_PROCESS)`) : fermer la
  console fermait Onyx.
- **Chaque mise à jour demandait les droits administrateur**, parce qu'Onyx est installé pour
  tous les utilisateurs dans `Program Files`.
- **Rien n'indiquait que la mise à jour était en cours** entre la fermeture de l'app et sa
  réouverture, à part la fenêtre de progression de l'installeur.

L'installation par Inno, elle, convient : droits admin, tous les utilisateurs, entrée dans
« Programmes et fonctionnalités », assistant aux couleurs de la marque. Elle n'a lieu qu'une fois.

## Décision

**Inno fait l'installation ; les mises à jour passent par `onyx-updater.exe`**, un petit
programme C++ Win32 sans console, compilé avec l'app et déposé à côté d'`app.exe`.

1. **Le paquet de mise à jour est le ZIP portable, signé.** La signature ECDSA P-256 voyage
   dans le commentaire du ZIP, que tous les outils ignorent : le même fichier reste le ZIP qu'on
   décompresse à la main, et le serveur n'a rien de nouveau à publier. La signature couvre le
   ZIP et sa version ; la clé publique est compilée dans l'exe, la clé privée est un secret de
   la CI.
2. **L'app télécharge le ZIP, lance `onyx-updater.exe apply` et quitte.** Le programme affiche
   une petite fenêtre « Mise à jour d'Onyx » (icône, texte, barre animée, dans l'esprit de
   Discord), attend la fin de l'app, applique la mise à jour, relance Onyx et ne se ferme qu'une
   fois la fenêtre de l'app visible.
3. **Dans `Program Files`, c'est un service qui écrit.** Inno installe le service
   `OnyxUpdater` (SYSTEM, démarrage manuel), avec les droits admin de l'installation. Tout
   utilisateur authentifié peut le démarrer, sans pouvoir le reconfigurer ni l'arrêter. Le
   service ne met à jour que son propre dossier, et n'accepte qu'un paquet signé, plus récent
   que la version installée, désigné par un chemin local. Il en fait une copie illisible des
   utilisateurs avant de la vérifier. Quand le dossier est inscriptible (ZIP portable), le
   programme fait le travail lui-même, sans service.
4. **Remplacement sur place, sans dossier par version.** Un exe ou une DLL en cours d'exécution
   ne peut pas être écrasé, mais peut être renommé. L'ancienne version part entière dans
   `.update-old-*`, la nouvelle prend sa place. Au moindre échec, chaque déplacement est défait.
   Les restes sont supprimés à la mise à jour suivante. Les fichiers de désinstallation d'Inno
   (`unins*`) ne bougent jamais.

## Conséquences

- Plus de console, plus de demande de droits admin après l'installation, et une fenêtre de mise
  à jour à la marque.
- **La mise à jour vers cette version passe encore par l'ancien mécanisme**, puisque c'est
  l'app installée qui l'applique : consoles et demande admin une dernière fois. C'est elle qui
  installe le service.
- **La clé de signature devient critique.** Sans elle dans la CI, le ZIP n'est pas signé et les
  postes Windows restent sur leur version. Perdue, il faut en générer une autre, et les versions
  déjà installées refuseront tout ce qu'elle signe : il faudra les réinstaller une fois.
- Les fichiers ajoutés par une mise à jour ne sont pas dans le journal de désinstallation
  d'Inno : la désinstallation supprime donc tout le dossier `{app}`.
- L'extraction s'appuie sur `tar.exe`, livré avec Windows depuis 10 (1803), et n'a lieu qu'une
  fois la signature vérifiée.

## Alternatives écartées

- **Installation par utilisateur** (`%LOCALAPPDATA%`) : plus de droits admin, mais plus
  d'installation pour tous les utilisateurs.
- **Ouvrir `Program Files\Onyx` en écriture à tous** : simple, mais n'importe quel compte, ou
  programme lancé sans droits, pourrait remplacer `app.exe`, puis un administrateur l'exécuterait.
- **Velopack** : installation par utilisateur par défaut, paquet Flutter communautaire, catalogue
  de versions à publier côté serveur, et plus d'assistant à la marque.
- **MSIX** : exige un certificat de signature reconnu.
