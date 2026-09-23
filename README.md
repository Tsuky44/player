<div align="center">

<img src="brand/onyx-lockup.svg" alt="Onyx" width="360" />

### Ton cinéma privé. Léger, rapide, sans compromis.

Onyx est un serveur multimédia auto-hébergé et son application, pensés pour une bibliothèque personnelle : **Direct Play en priorité**, un serveur qui consomme moins de 20 Mo de RAM, et un lecteur que tu personnalises comme tu veux.

![Go](https://img.shields.io/badge/Server-Go-00ADD8?logo=go&logoColor=white)
![Flutter](https://img.shields.io/badge/App-Flutter-02569B?logo=flutter&logoColor=white)
![SQLite](https://img.shields.io/badge/DB-SQLite-003B57?logo=sqlite&logoColor=white)
![Docker](https://img.shields.io/badge/Deploy-Docker-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/Licence-Tous%20droits%20r%C3%A9serv%C3%A9s-red)

</div>

---

## 📸 Aperçu

| Accueil | Fiche détail |
|:---:|:---:|
| ![Accueil](docs/screenshots/home.png) | ![Fiche](docs/screenshots/detail.png) |

| Lecteur | Player Studio |
|:---:|:---:|
| ![Lecteur](docs/screenshots/player.png) | ![Player Studio](docs/screenshots/studio.png) |

| Regarder ensemble | Mobile |
|:---:|:---:|
| ![Watch party](docs/screenshots/watch-party.png) | ![Mobile](docs/screenshots/mobile.png) |

---

## ✨ Fonctionnalités

### 🎬 Lecture
- **Direct Play pur** : le fichier est servi tel quel (HTTP Range, `206 Partial Content`), le seek est instantané et le CPU du serveur reste au repos.
- **Transcodage de secours** avec une échelle de débits, et un encodeur matériel si tu en as un.
- Décodage côté client via **mpv / media_kit**, et **ExoPlayer** sur Android.
- Pistes audio et sous-titres, downmix stéréo avec dialogues mis en avant.
- Aperçus sur la barre de lecture, saut d'intro, épisode suivant automatique.
- Image dans l'image, touches média du clavier.

### 🎨 Player Studio
- Un éditeur de disposition pour les contrôles du lecteur : tu places, déplaces et ajustes chaque bouton en glisser-déposer.
- Des thèmes de lecteur prêts à l'emploi.

### 👥 Regarder ensemble
- Des watch parties synchronisées : pause, lecture et seek sont partagés en temps réel entre tous les participants.

### 📚 Médiathèque
- Indexation automatique des films et séries (saisons / épisodes, motifs `SxxExx`), nettoyage des noms de fichiers.
- Surveillance des dossiers : les nouveaux fichiers apparaissent tout seuls.
- Identification des médias : affiches, fiches, casting, collections.
- Reprise de lecture synchronisée entre appareils, et même entre plusieurs serveurs liés.

### 🔐 Comptes et partage
- Le premier compte devient propriétaire. Les autres rejoignent sur **invitation**, avec des permissions fines.
- **Demandes de médias** pour les membres.
- Appairage d'une TV **par QR code**, sans taper de mot de passe.
- Connexion par QR sur le web et le desktop.

### 📥 Hors ligne
- Téléchargements pour regarder sans connexion, avec une réserve d'espace et un respect du réseau mobile facturé.

---

## 📱 Plateformes

| Plateforme | Statut |
|---|---|
| 🪟 Windows | ✅ avec mise à jour automatique |
| 🍎 macOS | ✅ |
| 🤖 Android / Android TV | ✅ |
| 📱 iOS | ✅ |
| 📺 Apple TV (tvOS) | ✅ |
| 🌐 Web | ✅ |

---

## 🏗️ Architecture

```
┌────────────────────────┐        HTTP / Range         ┌────────────────────────┐
│   App Onyx (Flutter)   │  ◄───────────────────────►  │   Serveur Onyx (Go)    │
│  mpv · ExoPlayer · UI  │        API REST + WS        │  SQLite (WAL) · ffmpeg │
└────────────────────────┘                             └───────────┬────────────┘
                                                                   │
                                                         📁 Tes films et séries
```

| Dossier | Contenu |
|---|---|
| [`server/`](server/) | Serveur Go : API, indexeur, streaming, transcodage |
| [`app/`](app/) | Application Flutter multiplateforme |
| [`brand/`](brand/) | Logo, icônes, identité visuelle |
| [`docs/adr/`](docs/adr/) | Les décisions d'architecture, une par fichier |

---

## 🚀 Démarrage rapide

### Serveur (Docker)

```bash
mkdir -p data media/Films media/Series
```

```bash
docker compose up -d --build
```

Le serveur tourne sur **http://localhost:8080**. Le premier compte créé devient le propriétaire.

La documentation complète de l'API est dans [`server/README.md`](server/README.md).

### Application

```bash
cd app
```

```bash
flutter pub get
```

```bash
flutter run
```

---

## 🧭 Philosophie

1. **Le contenu est le héros.** L'interface s'efface pendant la lecture.
2. **Direct Play d'abord.** On ne transcode que quand on n'a pas le choix.
3. **Léger.** Un serveur qui tourne sur un Raspberry Pi comme sur un NAS.
4. **Contrôle total.** Tes fichiers, ton serveur, aucun cloud.

---

## 📄 Licence

**© 2026 Tsuky. Tous droits réservés.**

Ce code est public pour être consulté, pas pour être réutilisé. Sans autorisation écrite de l'auteur, il est interdit de le copier, modifier, redistribuer ou l'utiliser commercialement. Voir [LICENSE](LICENSE).
