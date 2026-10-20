#!/usr/bin/env bash
# =============================================================================
# Construit le paquet .ipk du lanceur LG webOS (ADR-0076).
#
# Le paquet ne contient que app/webos/ : la page qui retient l'adresse du
# serveur et ouvre l'app web qu'il sert. L'app elle-même est le bundle de
# scripts/build-web.sh, embarqué dans le serveur : c'est lui qu'il faut
# reconstruire pour qu'un téléviseur voie un changement de l'app.
#
# Prérequis : les outils webOS (npm install -g @webos-tools/cli), qui
# fournissent ares-package, et ares-install pour l'envoyer au téléviseur.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/app/webos"
OUT_DIR="$ROOT_DIR/app/build/webos"
STAGE_DIR="$OUT_DIR/stage"

command -v ares-package >/dev/null || {
  echo "ares-package introuvable : npm install -g @webos-tools/cli" >&2
  exit 1
}

# La version du paquet : celle de la Release quand la CI la donne (ONYX_VERSION),
# sinon celle de pubspec.yaml sans le numéro de build. La CI ne réécrit pas
# pubspec.yaml — elle passe --build-name aux autres builds —, d'où la variable.
VERSION="${ONYX_VERSION:-$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$ROOT_DIR/app/pubspec.yaml")}"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "version invalide : '$VERSION' (format attendu : X.Y.Z)" >&2
  exit 1
}

echo "1. Préparation du lanceur $VERSION..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$SOURCE_DIR/." "$STAGE_DIR/"
sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$STAGE_DIR/appinfo.json"
rm -f "$STAGE_DIR/appinfo.json.bak"

echo "2. Paquet .ipk..."
ares-package "$STAGE_DIR" --outdir "$OUT_DIR"
rm -rf "$STAGE_DIR"

# Le nom des autres installateurs de la Release (Onyx-<version>-<plateforme>).
IPK="$OUT_DIR/Onyx-${VERSION}-webos.ipk"
mv -f "$OUT_DIR/com.tsuky.onyx_${VERSION}_all.ipk" "$IPK"

echo "Paquet : $IPK. Pour l'installer :"
echo "  ares-install --device <téléviseur> $IPK"
