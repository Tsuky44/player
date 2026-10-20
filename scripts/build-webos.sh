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

# La version du paquet suit celle de l'app (pubspec.yaml, sans le numéro de
# build) : le téléviseur refuse d'installer par-dessus une version égale.
VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$ROOT_DIR/app/pubspec.yaml")"
[ -n "$VERSION" ] || { echo "version introuvable dans app/pubspec.yaml" >&2; exit 1; }

echo "1. Préparation du lanceur $VERSION..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$SOURCE_DIR/." "$STAGE_DIR/"
sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$STAGE_DIR/appinfo.json"
rm -f "$STAGE_DIR/appinfo.json.bak"

echo "2. Paquet .ipk..."
ares-package "$STAGE_DIR" --outdir "$OUT_DIR"
rm -rf "$STAGE_DIR"

echo "Paquet dans $OUT_DIR. Pour l'installer :"
echo "  ares-install --device <téléviseur> $OUT_DIR/com.tsuky.onyx_${VERSION}_all.ipk"
