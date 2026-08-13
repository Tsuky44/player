#!/usr/bin/env bash
#
# Stages the installable client apps into server/downloads/, where the
# Dockerfile picks them up and the Go server publishes them on /api/downloads.
#
# Usage:
#   ./scripts/stage-downloads.sh [<dist-dir>]     # default: dist/latest
#
# Files are renamed to Onyx-<version>-<platform>.<ext> so the download URL of a
# given platform is stable, and the previous artifact of that same platform is
# removed — one file per platform, always the newest.
#
# Artifacts of platforms absent from <dist-dir> are left untouched: that is what
# lets a macOS publish keep the Windows EXE recovered from the previous image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
DIST_DIR="${1:-$ROOT_DIR/dist/latest}"
DOWNLOADS_DIR="$ROOT_DIR/server/downloads"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ ! -d "$DIST_DIR" ]]; then
    echo -e "${RED}ERREUR : dossier de build introuvable : $DIST_DIR${NC}" >&2
    exit 1
fi

# dist/latest est un lien symbolique vers le dossier horodaté du build, et find
# ne traverse pas un lien fourni comme point de départ : sans cette résolution,
# le staging ne trouve jamais rien. `-L` marcherait aussi, mais ferait suivre à
# find les liens internes des bundles .app.
DIST_DIR="$(cd "$DIST_DIR" && pwd -P)"

VERSION="$(
  python3 - <<'PY' "$ROOT_DIR/app/pubspec.yaml"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^version:\s*([^\s+]+)', text, re.M)
print(m.group(1) if m else '1.0.0')
PY
)"

mkdir -p "$DOWNLOADS_DIR"

# find_artifact <extension> [<name-to-skip>]
# Returns the largest matching file, which skips stubs and picks the real
# installer when a build leaves several candidates behind.
find_artifact() {
    local ext="$1" skip="${2:-}"
    find "$DIST_DIR" -type f -name "*.${ext}" \
        ${skip:+! -name "$skip"} \
        ! -path '*/.dmg-stage/*' \
        -exec ls -S {} + 2>/dev/null | head -1
}

# stage <platform> <extension> <source-file>
stage() {
    local platform="$1" ext="$2" src="$3"
    local dst="${DOWNLOADS_DIR}/Onyx-${VERSION}-${platform}.${ext}"

    # Drop any previous artifact for this platform, whatever its version.
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -name "*-${platform}.${ext}" -delete

    cp "$src" "$dst"
    printf "    ✓ %-16s → %s (%s)\n" "$platform" "$(basename "$dst")" "$(du -h "$dst" | cut -f1)"
}

echo -e "${YELLOW}Staging des applications depuis ${DIST_DIR}...${NC}"

STAGED=0

APK="$(find_artifact apk app-release.apk)"
if [[ -n "$APK" ]]; then stage android apk "$APK"; STAGED=$((STAGED + 1)); fi

DMG="$(find_artifact dmg)"
if [[ -n "$DMG" ]]; then stage macos dmg "$DMG"; STAGED=$((STAGED + 1)); fi

EXE="$(find_artifact exe)"
if [[ -n "$EXE" ]]; then stage windows exe "$EXE"; STAGED=$((STAGED + 1)); fi

ZIP="$(find_artifact zip)"
if [[ -n "$ZIP" ]]; then stage windows-portable zip "$ZIP"; STAGED=$((STAGED + 1)); fi

if [[ "$STAGED" -eq 0 ]]; then
    echo -e "${RED}Aucun artefact trouvé dans ${DIST_DIR}${NC}" >&2
    exit 1
fi

echo -e "${GREEN}=== server/downloads/ ===${NC}"
ls -lh "$DOWNLOADS_DIR" | grep -v '^total' | grep -v '\.gitkeep' || true
