#!/usr/bin/env bash
# =============================================================================
# Onyx — build iOS (.ipa)
# =============================================================================
# Usage:
#   ./scripts/build-ios-ipa.sh              # .ipa non signé, pour sideloading
#   ./scripts/build-ios-ipa.sh --signed     # .ipa signé par Xcode (compte Apple)
#
# Sortie :
#   dist/ios/Onyx-<version>.ipa
#
# Deux façons d'installer, et elles n'ont pas les mêmes prérequis :
#
#   1. Non signé (défaut). Le .ipa est une simple archive `Payload/Runner.app`
#      sans signature. Il ne s'installe pas tel quel : c'est **Sideloadly** ou
#      **AltStore** qui le resigne avec votre identifiant Apple au moment de
#      l'installation. Aucun compte développeur payant n'est nécessaire, mais
#      l'app expire au bout de 7 jours et doit être réinstallée.
#
#   2. Signé (`--signed`). Xcode signe avec l'équipe configurée dans le projet
#      (`DEVELOPMENT_TEAM`), ce qui demande un compte développeur Apple. Le
#      .ipa produit s'installe par Apple Configurator, TestFlight ou un MDM, et
#      dure ce que dure le profil de provisionnement.
#
# Prérequis communs : macOS, Xcode avec la plateforme iOS installée
# (Xcode ▸ Settings ▸ Components), CocoaPods.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
OUT_DIR="${ROOT_DIR}/dist/ios"

SIGNED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --signed) SIGNED=1; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Option inconnue: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
fail() { printf '    ✗ %s\n' "$*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "Un build iOS ne se fait que depuis macOS."
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  fail "flutter introuvable dans le PATH."
  exit 1
fi

# CocoaPods refuse de tourner sous une locale non UTF-8, et `pod install` est
# lancé par le build Flutter lui-même — donc c'est ici qu'il faut la poser.
export LANG="${LANG:-en_US.UTF-8}"

VERSION="$(
  python3 - <<'PY' "$APP_DIR/pubspec.yaml"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^version:\s*([^\s+]+)', text, re.M)
print(m.group(1) if m else '1.0.0')
PY
)"

mkdir -p "$OUT_DIR"
IPA_PATH="${OUT_DIR}/Onyx-${VERSION}.ipa"

cd "$APP_DIR"

log "flutter pub get"
flutter pub get

if [[ "$SIGNED" == "1" ]]; then
  log "flutter build ipa (signé)"
  flutter build ipa --release
  # `flutter build ipa` écrit dans build/ios/ipa/ sous le nom du produit.
  produced="$(find build/ios/ipa -maxdepth 1 -name '*.ipa' -print -quit)"
  if [[ -z "$produced" ]]; then
    fail "Aucun .ipa produit — regardez le rapport de validation Xcode ci-dessus."
    exit 1
  fi
  cp "$produced" "$IPA_PATH"
else
  log "flutter build ios --release --no-codesign"
  flutter build ios --release --no-codesign

  APP_BUNDLE="build/ios/iphoneos/Runner.app"
  if [[ ! -d "$APP_BUNDLE" ]]; then
    fail "Runner.app introuvable dans build/ios/iphoneos/."
    exit 1
  fi

  # Un .ipa est un zip contenant un dossier `Payload/`. Rien de plus : c'est le
  # même format que produit Xcode, moins la signature.
  log "empaquetage"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/Payload"
  cp -R "$APP_BUNDLE" "$STAGE/Payload/"
  # `_CodeSignature` d'un build non signé ne contient qu'une signature ad-hoc
  # que l'outil de sideloading remplacera ; la laisser fait parfois échouer la
  # resignature.
  rm -rf "$STAGE/Payload/Runner.app/_CodeSignature"
  rm -f "$IPA_PATH"
  (cd "$STAGE" && zip -qry "$IPA_PATH" Payload)
fi

SIZE="$(du -h "$IPA_PATH" | cut -f1 | tr -d ' ')"
ok "$IPA_PATH (${SIZE})"

if [[ "$SIGNED" != "1" ]]; then
  cat <<EOF

    Ce .ipa n'est pas signé. Pour l'installer sur un iPhone :
      • Sideloadly (https://sideloadly.io) — glissez le .ipa, entrez votre
        identifiant Apple, branchez le téléphone.
      • AltStore — même principe, avec un rafraîchissement automatique tant que
        le Mac est sur le même réseau.
    Sans compte développeur payant, l'app cesse de se lancer au bout de 7 jours ;
    il suffit de la réinstaller.
EOF
fi
