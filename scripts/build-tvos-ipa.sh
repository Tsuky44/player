#!/usr/bin/env bash
# =============================================================================
# Onyx — build Apple TV (.ipa)
# =============================================================================
# Usage:
#   ./scripts/build-tvos-ipa.sh              # .ipa non signé
#   ./scripts/build-tvos-ipa.sh --signed     # signé avec l'équipe du projet
#   ./scripts/build-tvos-ipa.sh --install    # signé, puis installé sur l'Apple TV
#
# Sortie :
#   dist/tvos/Onyx-<version>-tvos.ipa
#
# Flutter ne cible pas tvOS : le build passe par flutter-tvos (voir l'ADR-0028),
# installé et épinglé par ce script dans ~/.flutter-tvos.
#
# Installer sur une Apple TV demande une signature, et les outils de
# sideloading de l'iPhone (Sideloadly, AltStore) ne savent pas faire. Le plus
# simple est donc `--install` : l'Apple TV doit être appairée à ce Mac
# (Xcode ▸ Window ▸ Devices and Simulators, Apple TV et Mac sur le même
# réseau, Réglages ▸ Télécommandes et appareils ▸ App et appareils distants),
# et l'équipe `DEVELOPMENT_TEAM` du projet (tvos/Runner.xcodeproj) doit être
# la vôtre. Un identifiant Apple gratuit suffit ; l'app expire alors au bout
# de 7 jours, comme sur iPhone.
#
# Prérequis : macOS, Xcode avec la plateforme tvOS
# (Xcode ▸ Settings ▸ Components), CocoaPods.
# =============================================================================

set -euo pipefail

FLUTTER_TVOS_VERSION="v3.44.9-tvos.1.5.1"
FLUTTER_TVOS_DIR="${FLUTTER_TVOS_DIR:-$HOME/.flutter-tvos}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
OUT_DIR="${ROOT_DIR}/dist/tvos"

SIGNED=0
INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --signed) SIGNED=1; shift ;;
    --install) SIGNED=1; INSTALL=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Option inconnue: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "Un build tvOS ne se fait que depuis macOS."
  exit 1
fi

if ! xcodebuild -showsdks | grep -q appletvos; then
  fail "SDK tvOS absent : Xcode ▸ Settings ▸ Components ▸ tvOS."
  exit 1
fi

export LANG="${LANG:-en_US.UTF-8}"

# flutter-tvos, à la version épinglée. Il apporte son propre Flutter.
if [[ ! -d "$FLUTTER_TVOS_DIR/.git" ]]; then
  log "installation de flutter-tvos ${FLUTTER_TVOS_VERSION}"
  git clone --depth 1 --branch "$FLUTTER_TVOS_VERSION" \
    https://github.com/fluttertv/flutter-tvos.git "$FLUTTER_TVOS_DIR"
elif [[ "$(git -C "$FLUTTER_TVOS_DIR" describe --tags 2>/dev/null)" != "$FLUTTER_TVOS_VERSION" ]]; then
  log "flutter-tvos → ${FLUTTER_TVOS_VERSION}"
  git -C "$FLUTTER_TVOS_DIR" fetch --depth 1 origin tag "$FLUTTER_TVOS_VERSION"
  git -C "$FLUTTER_TVOS_DIR" checkout -q "$FLUTTER_TVOS_VERSION"
fi
export PATH="$FLUTTER_TVOS_DIR/bin:$PATH"
flutter-tvos precache

VERSION="$(
  python3 - <<'PY' "$APP_DIR/pubspec.yaml"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^version:\s*([^\s+]+)', text, re.M)
print(m.group(1) if m else '1.0.0')
PY
)"

mkdir -p "$OUT_DIR"
IPA_PATH="${OUT_DIR}/Onyx-${VERSION}-tvos.ipa"

cd "$APP_DIR"

if [[ "$INSTALL" == "1" ]]; then
  log "flutter-tvos run --release (Apple TV appairée)"
  exec flutter-tvos run --release
fi

if [[ "$SIGNED" == "1" ]]; then
  log "flutter-tvos build tvos --release"
  flutter-tvos build tvos --release
else
  # Pas de --no-codesign à cette version de flutter-tvos : la signature est
  # coupée par un xcconfig imposé à xcodebuild (même méthode que la CI).
  log "flutter-tvos build tvos --release (sans signature)"
  XCCONFIG="$(mktemp -t onyx-no-codesign).xcconfig"
  printf '%s\n' \
    'CODE_SIGNING_ALLOWED = NO' \
    'CODE_SIGNING_REQUIRED = NO' \
    'CODE_SIGN_IDENTITY =' \
    'EXPANDED_CODE_SIGN_IDENTITY =' > "$XCCONFIG"
  XCODE_XCCONFIG_FILE="$XCCONFIG" flutter-tvos build tvos --release
  rm -f "$XCCONFIG"
fi

APP_BUNDLE="build/tvos/Release-appletvos/Runner.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  fail "Runner.app introuvable dans build/tvos/Release-appletvos/."
  exit 1
fi

log "empaquetage"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP_BUNDLE" "$STAGE/Payload/"
if [[ "$SIGNED" != "1" ]]; then
  rm -rf "$STAGE/Payload/Runner.app/_CodeSignature"
fi
rm -f "$IPA_PATH"
(cd "$STAGE" && zip -qry "$IPA_PATH" Payload)

SIZE="$(du -h "$IPA_PATH" | cut -f1 | tr -d ' ')"
ok "$IPA_PATH (${SIZE})"
