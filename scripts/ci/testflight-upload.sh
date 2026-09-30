#!/usr/bin/env bash
# =============================================================================
# Onyx — envoi d'une archive Xcode sur TestFlight (CI)
# =============================================================================
# Usage (depuis la CI, sur un runner macOS) :
#   scripts/ci/testflight-upload.sh <chemin/vers/Runner.xcarchive>
#
# Variables d'environnement requises :
#   ASC_KEY_ID      Key ID de la cle API App Store Connect
#   ASC_ISSUER_ID   Issuer ID de l'equipe
#   ASC_KEY_P8      contenu du fichier AuthKey_<id>.p8
#
# L'archive peut etre non signee : xcodebuild la signe a l'export avec les
# certificats de distribution qu'Apple gere dans le cloud, puis l'envoie a App
# Store Connect (destination=upload). Aucun .p12 ni profil a entretenir, mais
# la cle doit avoir le role Admin, le seul autorise a utiliser ces
# certificats. La plateforme (iOS, tvOS) est deduite de l'archive, d'ou un
# seul script pour les deux jobs de release.yml.
# =============================================================================

set -euo pipefail

ARCHIVE="${1:?Usage: $0 <chemin/vers/.xcarchive>}"
: "${ASC_KEY_ID:?ASC_KEY_ID manquant}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID manquant}"
: "${ASC_KEY_P8:?ASC_KEY_P8 manquant}"

if [[ ! -d "$ARCHIVE" ]]; then
  echo "::error::Archive introuvable : $ARCHIVE" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY_PATH="$WORK/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$KEY_PATH"

# L'equipe est celle des projets Xcode (DEVELOPMENT_TEAM). Les numeros de
# version et de build viennent de l'archive : les laisser a Xcode les
# desynchroniserait de la Release GitHub.
PLIST="$WORK/ExportOptions.plist"
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>J399YTMT5R</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PLIST" \
  -exportPath "$WORK/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
