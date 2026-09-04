#!/usr/bin/env bash
# Régénère toutes les icônes d'app Onyx à partir des SVG de brand/.
#
# N'utilise que des outils livrés avec macOS : qlmanage (moteur WebKit) pour
# rasteriser le SVG en 1024, sips pour redescendre aux tailles exactes, et un
# court script python3 pour empaqueter le .ico Windows.
#
#   ./brand/generate-icons.sh
set -euo pipefail

brand="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$(dirname "$brand")/app"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# rasterise <source.svg> <nom> -> $tmp/<nom>.png en 1024x1024
rasterise() {
  qlmanage -t -s 1024 -o "$tmp" "$brand/$1" >/dev/null 2>&1
  mv "$tmp/$1.png" "$tmp/$2.png"
}

rasterise onyx-icon-macos.svg macos
rasterise onyx-icon-square.svg square
rasterise onyx-icon-maskable.svg maskable

# resize <nom> <taille> <destination>
resize() {
  mkdir -p "$(dirname "$3")"
  sips -z "$2" "$2" "$tmp/$1.png" --out "$3" >/dev/null
}

echo "macOS…"
for size in 16 32 64 128 256 512 1024; do
  resize macos "$size" "$app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
done

echo "Android…"
resize square 48 "$app/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
resize square 72 "$app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
resize square 96 "$app/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png"
resize square 144 "$app/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png"
resize square 192 "$app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"

echo "Web…"
resize square 192 "$app/web/icons/Icon-192.png"
resize square 512 "$app/web/icons/Icon-512.png"
resize maskable 192 "$app/web/icons/Icon-maskable-192.png"
resize maskable 512 "$app/web/icons/Icon-maskable-512.png"
resize square 32 "$app/web/favicon.png"

echo "iOS…"
# Les icônes iOS sont plein cadre et sans transparence : c'est le système qui
# arrondit les coins. Les noms de fichiers sont ceux du modèle Flutter, qui
# sont référencés par `AppIcon.appiconset/Contents.json`.
ios_icons="$app/ios/Runner/Assets.xcassets/AppIcon.appiconset"
for spec in 20:1 20:2 20:3 29:1 29:2 29:3 40:1 40:2 40:3 60:2 60:3 76:1 76:2; do
  pt="${spec%%:*}"
  scale="${spec##*:}"
  resize square "$((pt * scale))" "$ios_icons/Icon-App-${pt}x${pt}@${scale}x.png"
done
resize square 167 "$ios_icons/Icon-App-83.5x83.5@2x.png"
resize square 1024 "$ios_icons/Icon-App-1024x1024@1x.png"

echo "Windows…"
for size in 16 32 48 64 128 256; do
  resize square "$size" "$tmp/ico_$size.png"
done
python3 - "$tmp" "$app/windows/runner/resources/app_icon.ico" <<'PY'
import struct, sys

tmp, out = sys.argv[1], sys.argv[2]
sizes = [16, 32, 48, 64, 128, 256]
blobs = [open(f"{tmp}/ico_{s}.png", "rb").read() for s in sizes]

# Un .ico est un ICONDIR suivi d'une ICONDIRENTRY par image ; depuis Vista les
# images peuvent être des PNG bruts, ce qui évite d'encoder du BMP à la main.
offset = 6 + 16 * len(sizes)
header = struct.pack("<HHH", 0, 1, len(sizes))
entries, payload = b"", b""
for size, blob in zip(sizes, blobs):
    entries += struct.pack(
        "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset
    )
    payload += blob
    offset += len(blob)
open(out, "wb").write(header + entries + payload)
PY

echo "OK"
