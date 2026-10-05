# ADR-0042 — L'adresse du serveur est déduite de l'origine de l'installeur

- **Statut :** accepté, en cours. Le Go et le Dart sont testés, l'APK annoté est validé par
  `apksigner` et relu par le Dart, le script Inno compile. **Rien n'a encore été essayé sur un
  appareil** : ni l'installation Windows, ni l'APK sur un téléphone, ni l'IPA resigné, ni la
  lecture de la quarantaine sur un Mac.
- **Date :** 2026-10-05
- **Portée :** le service des installeurs (`server/installorigin`, `ServeDownload`), l'installeur
  Windows (`app/installer.iss`), l'adresse par défaut du client
  (`app/lib/services/install_origin*.dart`, `ApiClient._loadConfig`). Le web ne change pas : son
  origine est déjà le serveur.

## Contexte

L'installeur se télécharge depuis l'app web, donc depuis le serveur qu'on va utiliser
(`https://mon-serveur/api/downloads/Onyx-1.2.0-windows.exe`). Au premier lancement, l'écran de
connexion proposait pourtant `http://127.0.0.1:8080`, et il fallait retaper l'adresse qu'on
venait de quitter — au D-pad sur un téléviseur.

## Décision

**L'app retrouve l'adresse du téléchargement de son installeur, et en tire celle du serveur.**
Chaque plateforme la range ailleurs ; toutes aboutissent au même texte, une ligne
`HostUrl=<adresse du téléchargement>`, et à la même règle d'extraction.

| Plateforme | Qui note l'adresse | Où l'app la relit |
|---|---|---|
| Windows | Windows, dans le flux `Zone.Identifier` de l'exe téléchargé ; Inno le recopie en fin d'installation | `%ProgramData%\Onyx\install-origin.txt` |
| macOS | macOS, dans sa base des événements de quarantaine | l'attribut `com.apple.quarantine` de l'app donne l'identifiant, `sqlite3` l'adresse |
| Android | le serveur, au moment de servir l'APK | une paire de l'« APK Signing Block » de son propre APK |
| iOS, tvOS | le serveur, au moment de servir l'IPA | `install-origin.txt` dans le bundle |

1. **Le serveur annote au vol, sans toucher au disque.** `installorigin.Stamp` rend une vue du
   fichier où quelques octets sont intercalés ; `Range` continue de fonctionner. L'adresse écrite
   est celle de la requête (`X-Forwarded-Proto` + `Host` + chemin), donc celle du reverse proxy
   quand il y en a un.
2. **L'APK reste valablement signé.** L'APK Signing Block n'est couvert par aucune signature
   (v2, v3) : y ajouter une paire est l'usage prévu. Seul le décalage du répertoire central
   change, et la vérification v2 le neutralise d'elle-même.
3. **L'IPA publié n'est pas signé** (ADR-0011) : Sideloadly ou AltStore signent le bundle tel
   qu'ils le trouvent, marqueur compris.
4. **Sur Windows et macOS, le fichier servi n'est pas modifié** : le système note déjà la
   provenance. Sur Windows le marqueur va dans `ProgramData` et non dans le dossier de l'app,
   qu'une mise à jour déplace en entier (ADR-0030).
5. **L'adresse n'est retenue que si elle passe par `/api/downloads/`** : ce qui précède la route
   est la racine du serveur, sous-chemin de reverse proxy compris. Un installeur pris sur GitHub
   ne préremplit rien.
6. **Elle ne sert que d'adresse par défaut**, quand aucune adresse n'a jamais été saisie et
   qu'aucun compte n'existe. Elle ne remplace jamais un choix de l'utilisateur.

## Conséquences

- Un APK ou un IPA servi fait quelques dizaines d'octets de plus que le `size` de
  `GET /api/downloads`, et diffère d'un nom d'hôte à l'autre. Les fichiers de la GitHub Release,
  eux, ne portent rien.
- Rien n'est prérempli quand la trace manque : navigation privée sous Windows (le navigateur
  écrit `about:internet`), fichier passé par une clé USB ou « débloqué », APK signé v1 seulement,
  IPA sans `Payload/*.app`, archive ZIP64. On retombe sur le comportement d'avant, et un
  installeur qu'on ne sait pas annoter part tel quel.
- Un IPA signé (`build-ios-ipa.sh --signed`) ne supporterait pas le fichier ajouté : le jour où
  il est publié, l'annotation des IPA doit être coupée.
- L'adresse écrite vient de l'en-tête `Host` de la requête. Celui qui télécharge peut donc la
  fausser, mais seulement dans le fichier qu'il reçoit lui-même.
- Sur macOS, le premier lancement sans adresse connue lance `xattr` et `sqlite3` (deux
  processus, une fois).

## Alternatives écartées

- **Glisser l'adresse dans le nom du fichier** (`Onyx-1.2.0@mon-serveur.exe`) : cassé au premier
  renommage, illisible pour une app Android ou iOS, et le nom sert déjà à lire la version.
- **Un paramètre `?origin=` choisi par le client** : un lien forgé sur un serveur légitime
  distribuerait une app pointant ailleurs.
- **Écrire dans le commentaire du ZIP de l'APK** : l'enregistrement de fin est couvert par la
  signature v2.
- **Annoter l'exe et le DMG côté serveur** : inutile, le système le fait, et cela casserait une
  future signature Authenticode ou une notarisation.
