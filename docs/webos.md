# Installer Onyx sur un téléviseur LG (webOS)

L'app LG est un lanceur : il retient l'adresse du serveur et ouvre l'app web que ce
serveur sert. La lecture passe par le décodeur du téléviseur, en Direct Play (ADR-0076).
Conséquences :

- **L'app suit le serveur.** Mettre le serveur à jour met l'app à jour sur le téléviseur. Le
  `.ipk` ne se réinstalle que si le lanceur lui-même change.
- **Cible** : webOS 6 (2021) et après.

Le paquet n'est pas publié sur le LG Content Store : il s'installe en **mode développeur**.

## 1. Récupérer le paquet

Chaque Release GitHub porte `Onyx-<version>-webos.ipk` (job `build-webos` de
`.github/workflows/release.yml`). Pour le construire soi-même :

```bash
npm install -g @webos-tools/cli
```

```bash
bash scripts/build-webos.sh
```

Le paquet arrive dans `app/build/webos/`. Sous Windows, `scripts/build-webos.ps1` fait la même
chose.

## 2. Mettre le serveur à jour

Le serveur doit embarquer l'app web d'une version qui connaît webOS. Sur la machine du
serveur :

```bash
docker compose pull
```

```bash
docker compose up -d
```

## 3. Passer le téléviseur en mode développeur

1. Créer un compte gratuit sur le site **LG webOS TV Developer**.
2. Sur le téléviseur, installer l'app **Developer Mode** depuis le LG Content Store et s'y
   connecter avec ce compte.
3. Activer **Dev Mode Status** ; le téléviseur redémarre.
4. Rouvrir Developer Mode, activer **Key Server**, et noter l'adresse IP et la **passphrase**
   affichées.

La session de développeur dure 50 heures. Le bouton **Extend Session Time** de l'app la
prolonge. Une session expirée désinstalle les apps de développement : il faut alors la
prolonger puis réinstaller le paquet.

## 4. Déclarer le téléviseur sur l'ordinateur

L'ordinateur et le téléviseur doivent être sur le même réseau. Les outils viennent de
`npm install -g @webos-tools/cli` (Node 20 ou plus).

```bash
ares-setup-device --add matele --info "{'host':'IP_DU_TELEVISEUR','port':'9922','username':'prisoner'}"
```

```bash
ares-novacom --device matele --getkey
```

La seconde commande demande la passphrase affichée par Developer Mode.

## 5. Installer et lancer

```bash
ares-install --device matele Onyx-1.0.35-webos.ipk
```

```bash
ares-launch --device matele com.tsuky.onyx
```

Onyx apparaît aussi dans la liste des apps du téléviseur. Au premier lancement, saisir
l'adresse du serveur, par exemple `192.168.1.20:8080` (le port 8080 est ajouté s'il manque).
Aux lancements suivants, l'app ouvre ce serveur seule. Pendant 1,5 seconde, **Changer de
serveur** permet d'en choisir un autre.

Pour se connecter, l'écran de connexion affiche un QR à scanner avec un téléphone déjà connecté
à Onyx, à côté du formulaire identifiant / mot de passe.

## Mettre à jour, désinstaller, déboguer

Réinstaller par-dessus avec `ares-install` met le lanceur à jour.

```bash
ares-install --device matele --remove com.tsuky.onyx
```

```bash
ares-inspect --device matele --app com.tsuky.onyx --open
```

La dernière commande ouvre les DevTools de Chrome sur la page du téléviseur. Lignes utiles
dans la console :

- `PlaybackCapabilities: webOS (...)` : ce que le téléviseur déclare lire ;
- `Player: Direct Play refusé` : un fichier que le téléviseur a refusé et qui est passé en HLS.

## Limites connues

- Le repli HLS charge hls.js depuis cdnjs : sans accès Internet, le Direct Play fonctionne
  mais pas le repli.
- Retour, à l'accueil de l'app, ne la quitte pas : c'est la touche Accueil du téléviseur qui le
  fait.
