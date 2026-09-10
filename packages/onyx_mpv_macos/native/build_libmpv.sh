#!/usr/bin/env bash
# Construit le libmpv de développement d'Onyx pour macOS.
#
# mpv 0.41.0 + les patchs de patches/ (intégration dans une vue hôte par
# --wid), avec Vulkan/MoltenVK et libplacebo pour vo=gpu-next — le seul
# moteur de mpv qui applique le Dolby Vision. Les dépendances viennent de
# Homebrew : le binaire produit n'est utilisable que sur cette machine.
#
# Usage : ./build_libmpv.sh
# Le résultat est installé dans ~/Library/Application Support/Onyx/libmpv/,
# où l'app le trouve et s'en sert par défaut. --dart-define=ONYX_LIBMPV=<chemin>
# reste possible pour en essayer un autre.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/.build"
SRC="$BUILD/mpv-src"
MESON_DIR="$BUILD/meson"
OUT="$BUILD/out"
MPV_TAG="v0.41.0"

DEPS=(meson ninja pkgconf ffmpeg libplacebo little-cms2 vulkan-loader molten-vk libass uchardet zimg)
if ! brew list --versions "${DEPS[@]}" >/dev/null 2>&1; then
  echo "Dépendances manquantes. Installer avec :" >&2
  echo "  brew install ${DEPS[*]}" >&2
  exit 1
fi

mkdir -p "$BUILD"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git "$SRC"
fi

# Les sources repartent toujours de la version publiée : les patchs sont la
# seule source de vérité des modifications.
git -C "$SRC" reset --hard --quiet
git -C "$SRC" clean -fdq
for patch in "$HERE"/patches/*.patch; do
  git -C "$SRC" apply --whitespace=nowarn "$patch"
done

export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"

MESON_ARGS=(
  --buildtype=release
  --prefix="$OUT"
  -Dlibmpv=true -Dcplayer=false -Dgpl=false
  -Dbuild-date=false -Dtests=false
  -Dcocoa=enabled -Dswift-build=enabled
  -Dvulkan=enabled -Dvideotoolbox-pl=enabled
  -Dcoreaudio=enabled -Dlcms2=enabled -Duchardet=enabled -Dzimg=enabled
  # Ce qui toucherait l'app hôte : le centre « À l'écoute » et la Touch Bar.
  -Dmacos-media-player=disabled -Dmacos-touchbar=disabled
  -Dmacos-cocoa-cb=disabled
  -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled
  -Dlibbluray=disabled -Drubberband=disabled -Dvapoursynth=disabled
  -Dcdda=disabled -Ddvdnav=disabled -Ddvbin=disabled -Djpeg=disabled
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
)

if [ -d "$MESON_DIR" ]; then
  meson setup --reconfigure "$MESON_DIR" "$SRC" "${MESON_ARGS[@]}"
else
  meson setup "$MESON_DIR" "$SRC" "${MESON_ARGS[@]}"
fi
meson compile -C "$MESON_DIR"
meson install -C "$MESON_DIR" >/dev/null

INSTALL_DIR="$HOME/Library/Application Support/Onyx/libmpv"
mkdir -p "$INSTALL_DIR"
cp "$OUT/lib/libmpv.2.dylib" "$INSTALL_DIR/libmpv.2.dylib"

echo
echo "libmpv construit : $OUT/lib/libmpv.2.dylib"
echo "libmpv installé  : $INSTALL_DIR/libmpv.2.dylib (utilisé par défaut par l'app)"
