#!/usr/bin/env bash
#
# Builds the Flutter Web bundle and stages it for embedding into the Go binary.
#
# The output lands in server/webui/dist/, which webui.go embeds with go:embed.
# Run this before `go build` or before publish-image.sh — publish-image.sh calls
# it automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
APP_DIR="$ROOT_DIR/app"
DIST_DIR="$ROOT_DIR/server/webui/dist"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if ! command -v flutter &>/dev/null; then
    echo -e "${RED}ERREUR : flutter introuvable dans le PATH.${NC}" >&2
    exit 1
fi

echo -e "${YELLOW}1. Build du bundle Flutter Web...${NC}"
# --no-web-resources-cdn est obligatoire ici : par defaut Flutter va chercher
# CanvasKit (son moteur de rendu) sur https://www.gstatic.com. Un serveur media
# auto-heberge doit s'afficher meme quand le reseau du spectateur bloque Google,
# et sans signaler chaque visiteur a un tiers.
# --pwa-strategy=none supprime le service worker. Celui de Flutter sert l'app
# offline-first depuis le CacheStorage du navigateur : il court-circuite les
# en-tetes HTTP, rend l'ancienne version au chargement suivant un deploiement et
# n'active la nouvelle qu'au chargement d'apres. Un client de serveur media
# auto-heberge n'a aucun besoin de fonctionner hors ligne. Flutter le declare
# lui-meme deprecie.
(cd "$APP_DIR" && flutter build web --release --no-web-resources-cdn --pwa-strategy=none)

echo -e "${YELLOW}2. Copie vers server/webui/dist/...${NC}"
# Wipe everything but the placeholder, so files removed by a Flutter upgrade
# don't linger inside the binary forever.
find "$DIST_DIR" -mindepth 1 ! -name '.gitkeep' -delete
cp -R "$APP_DIR/build/web/." "$DIST_DIR/"

echo -e "${YELLOW}3. Nettoyage des artefacts inutilises...${NC}"
# Les .symbols sont des tables de symboles pour le debugger : jamais demandees
# par un navigateur, plusieurs Mo chacune, et elles finiraient dans le binaire.
find "$DIST_DIR" -name '*.symbols' -delete

# skwasm / wimp ne sont charges que par un build WasmGC (`flutter build web
# --wasm`). Ce projet ne peut pas en faire un : flutter_secure_storage_web
# depend de dart:html, que WasmGC ne supporte pas. Ces ~17 Mo seraient donc
# embarques dans le binaire sans qu'aucun navigateur ne les demande jamais.
# Idem pour experimental_webparagraph, non selectionne par defaut.
#
# Ce qui reste est necessaire : canvaskit/chromium/ sert Chrome et Edge,
# canvaskit/canvaskit.wasm sert Safari et Firefox.
find "$DIST_DIR/canvaskit" \( -name 'skwasm*' -o -name 'wimp*' \) -delete
rm -rf "$DIST_DIR/canvaskit/experimental_webparagraph"

echo -e "${YELLOW}4. Service worker d'auto-désinstallation...${NC}"
# Ne plus generer de service worker ne desinstalle pas ceux deja enregistres :
# ils continueraient a servir leur cache indefiniment. Le navigateur reverifie
# periodiquement le script a son URL d'origine, il faut donc y repondre.
#
# Et il faut y repondre par du JavaScript : le handler Go renvoie index.html
# pour tout chemin inconnu (fallback SPA), donc supprimer le fichier ferait
# parvenir du HTML au navigateur, la mise a jour du worker echouerait, et
# l'ancien resterait en place. D'ou ce remplacant minimal, qui vide les caches,
# se desinscrit, puis recharge les onglets ouverts une fois.
cat > "$DIST_DIR/flutter_service_worker.js" <<'SW'
// Remplacant du service worker de Flutter, retire via --pwa-strategy=none.
// Son seul role est de desinstaller les workers encore enregistres chez les
// clients qui ont visite une version precedente. A supprimer quand le parc
// aura tourne.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      await caches.delete(key);
    }
    await self.registration.unregister();
    for (const client of await self.clients.matchAll({ type: 'window' })) {
      client.navigate(client.url);
    }
  })());
});
SW

echo -e "${YELLOW}5. Pré-compression gzip des assets texte...${NC}"
# Pre-compresser au build veut dire que le serveur n'y depense aucun CPU, et que
# le bundle reste petit meme si le reverse proxy devant n'a pas gzip active.
# -k garde l'original : les clients qui n'envoient pas Accept-Encoding en ont
# encore besoin.
find "$DIST_DIR" \
    \( -name '*.js' -o -name '*.json' -o -name '*.html' \
    -o -name '*.css' -o -name '*.wasm' \) \
    -size +1k -exec gzip -9 -k -f {} \;

RAW_SIZE=$(du -sh "$DIST_DIR" | cut -f1)
echo -e "${GREEN}=== Bundle web prêt (${RAW_SIZE}) dans server/webui/dist/ ===${NC}"
