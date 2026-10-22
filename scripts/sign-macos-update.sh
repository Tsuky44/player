#!/bin/sh
# Signe le bundle Onyx.app d'un DMG pour la mise à jour automatique macOS.
#
# L'app installée ne remplace plus son bundle que par un bundle signé par la
# clé des mises à jour Windows (ADR-0030, ONYX_UPDATE_SIGNING_KEY, PKCS#8 en
# base64) : voir app/lib/services/macos_update_signature_io.dart.
#
#   signé = "onyx-update-macos-v1\n" + version + "\n" + empreinte du bundle
#
# La signature ECDSA P-256 (DER) est écrite dans <sortie>, à placer à la
# racine du volume du DMG sous le nom .onyx-update.sig.
#
#   ONYX_UPDATE_SIGNING_KEY=… scripts/sign-macos-update.sh Onyx.app 1.2.3 .onyx-update.sig
set -eu

if [ $# -ne 3 ]; then
  echo "usage: $0 <Onyx.app> <version> <sortie>" >&2
  exit 2
fi
app=$1
version=$2
out=$3

case "$version" in
  *[!0-9.]* | "") echo "Version invalide : '$version' (X.Y.Z attendu)" >&2; exit 2 ;;
esac
if [ -z "${ONYX_UPDATE_SIGNING_KEY:-}" ]; then
  echo "ONYX_UPDATE_SIGNING_KEY absent." >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Tout sauf l'alphabet base64 est retiré, comme dans sign-windows-update.ps1 :
# un secret collé arrive parfois avec des retours à la ligne.
printf '%s' "$ONYX_UPDATE_SIGNING_KEY" | tr -cd 'A-Za-z0-9+/=' > "$work/key.b64"
openssl base64 -d -A -in "$work/key.b64" -out "$work/key.der"
openssl pkey -inform DER -in "$work/key.der" -out "$work/key.pem"

digest=$(python3 "$(dirname "$0")/macos_bundle_digest.py" "$app")
printf 'onyx-update-macos-v1\n%s\n%s' "$version" "$digest" > "$work/message"
openssl dgst -sha256 -sign "$work/key.pem" -out "$out" "$work/message"
echo "Signé : $app (version $version)"
