#!/usr/bin/env bash
# Construit OnyxMpv.xcframework : le libmpv livrable d'Onyx pour macOS.
#
# mpv 0.41.0 + les patchs de patches/, universel (arm64 + x86_64) et
# autonome : chaque dépendance est compilée ici en statique et liée dans un
# seul binaire qui ne dépend que des frameworks du système. FFmpeg est
# construit sans --enable-gpl et mpv avec -Dgpl=false : l'ensemble est LGPL.
#
# Usage : ./build_release.sh
# Résultat : ../macos/Frameworks/OnyxMpv.xcframework, embarqué par le podspec.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.build/release"
SRC="$ROOT/src"
LOGS="$ROOT/logs"
DEST="$HERE/../macos/Frameworks"
MACOS_MIN="11.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
JOBS="$(sysctl -n hw.ncpu)"

FFMPEG=8.1
DAV1D=1.5.3
FREETYPE=2.14.3
HARFBUZZ=14.4.0
FRIBIDI=1.0.16
LIBASS=0.17.4
GLSLANG=16.5.0
LIBPLACEBO=v7.360.1
MPV=v0.41.0
MOLTENVK=v1.4.2

for tool in meson ninja cmake nasm pkg-config git curl; do
  command -v "$tool" >/dev/null || { echo "Outil manquant : $tool (brew install $tool)" >&2; exit 1; }
done

mkdir -p "$SRC" "$LOGS"

step() { echo "==> $*"; }

# Envoie la sortie d'une commande dans un journal ; en cas d'échec, montre la
# fin du journal plutôt que de tout déverser.
run() {
  local log="$1"; shift
  if ! "$@" >>"$log" 2>&1; then
    echo "ÉCHEC : $*" >&2
    tail -40 "$log" >&2
    exit 1
  fi
}

fetch() {
  local dir="$1" file="$2" url="$3"
  [ -d "$SRC/$dir" ] && return 0
  step "téléchargement de $file"
  curl -fsSL "$url" -o "$SRC/$file"
  tar -xf "$SRC/$file" -C "$SRC"
  rm -f "$SRC/$file"
}

clone() {
  local dir="$1" tag="$2" url="$3"
  [ -d "$SRC/$dir" ] && return 0
  step "clone de $dir $tag"
  git clone -q --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules "$url" "$SRC/$dir"
}

fetch "ffmpeg-$FFMPEG" "ffmpeg-$FFMPEG.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz"
fetch "dav1d-$DAV1D" "dav1d-$DAV1D.tar.xz" "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D/dav1d-$DAV1D.tar.xz"
fetch "freetype-$FREETYPE" "freetype-$FREETYPE.tar.xz" "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE/freetype-$FREETYPE.tar.xz"
fetch "harfbuzz-$HARFBUZZ" "harfbuzz-$HARFBUZZ.tar.xz" "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ/harfbuzz-$HARFBUZZ.tar.xz"
fetch "fribidi-$FRIBIDI" "fribidi-$FRIBIDI.tar.xz" "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI/fribidi-$FRIBIDI.tar.xz"
fetch "libass-$LIBASS" "libass-$LIBASS.tar.xz" "https://github.com/libass/libass/releases/download/$LIBASS/libass-$LIBASS.tar.xz"
fetch "glslang-$GLSLANG" "glslang-$GLSLANG.tar.gz" "https://github.com/KhronosGroup/glslang/archive/refs/tags/$GLSLANG.tar.gz"
fetch MoltenVK "MoltenVK-macos.tar" "https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK/MoltenVK-macos.tar"
clone libplacebo "$LIBPLACEBO" https://code.videolan.org/videolan/libplacebo.git
clone mpv "$MPV" https://github.com/mpv-player/mpv.git

# Les sources de mpv repartent toujours de la version publiée : les patchs
# sont la seule source de vérité des modifications.
git -C "$SRC/mpv" reset --hard --quiet
git -C "$SRC/mpv" clean -fdq
for patch in "$HERE"/patches/*.patch; do
  git -C "$SRC/mpv" apply --whitespace=nowarn "$patch"
done

cross_file() {
  local out="$1" arch="$2" family="$3" prefix="$4" extra_link="$5"
  local flags="'-arch', '$arch', '-mmacosx-version-min=$MACOS_MIN', '-isysroot', '$SDK', '-I$prefix/include'"
  cat > "$out" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
nasm = 'nasm'
cmake = 'cmake'

[properties]
needs_exe_wrapper = false
pkg_config_libdir = '$prefix/lib/pkgconfig'

[built-in options]
c_args = [$flags]
cpp_args = [$flags]
objc_args = [$flags]
objcpp_args = [$flags]
c_link_args = [$flags$extra_link]
cpp_link_args = [$flags$extra_link]
objc_link_args = [$flags$extra_link]
objcpp_link_args = [$flags$extra_link]
cmake_prefix_path = '$prefix'

[host_machine]
system = 'darwin'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
}

build_arch() {
  local arch="$1"
  local prefix="$ROOT/$arch/prefix"
  local work="$ROOT/$arch/work"
  local log="$LOGS/$arch"
  local family=x86_64
  [ "$arch" = arm64 ] && family=aarch64

  # Chaque dépendance installée laisse un marqueur (.done-<nom>) et est sautée
  # ensuite : relancer après un échec reprend là où il s'est arrêté.
  # FRESH=1 repart de zéro.
  if [ "${FRESH:-0}" = 1 ]; then rm -rf "$prefix" "$work" "$log"; fi
  mkdir -p "$prefix/lib/pkgconfig" "$work" "$log"
  cross_file "$work/cross.ini" "$arch" "$family" "$prefix" ""
  cross_file "$work/cross-mpv.ini" "$arch" "$family" "$prefix" ", '-lc++'"

  done_step() { [ -f "$prefix/.done-$1" ] && echo "==> $arch : $1 (déjà construit)"; }

  mbuild() {
    local name="$1" srcdir="$2"; shift 2
    done_step "$name" && return 0
    step "$arch : $name"
    rm -rf "$work/$name"
    : > "$log/$name.log"
    run "$log/$name.log" meson setup "$work/$name" "$srcdir" --cross-file "$work/cross.ini" \
      --prefix "$prefix" --libdir lib --buildtype release --default-library static "$@"
    run "$log/$name.log" meson compile -C "$work/$name"
    run "$log/$name.log" meson install -C "$work/$name"
    rm -rf "$work/$name"
    touch "$prefix/.done-$name"
  }

  # MoltenVK : Vulkan sur Metal, livré précompilé. Lié en statique à la place
  # d'un chargeur Vulkan, il n'y a plus d'ICD à installer à côté de l'app.
  step "$arch : MoltenVK"
  lipo -thin "$arch" -output "$prefix/lib/libMoltenVK.a" \
    "$SRC/MoltenVK/MoltenVK/static/MoltenVK.xcframework/macos-arm64_x86_64/libMoltenVK.a"
  cat > "$prefix/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=$SRC/MoltenVK/MoltenVK/include

Name: vulkan
Description: MoltenVK (Vulkan sur Metal), lié en statique
Version: 1.4.0
Libs: -L\${libdir} -lMoltenVK -lc++ -framework Metal -framework IOSurface -framework QuartzCore -framework CoreGraphics -framework IOKit -framework Foundation -framework AppKit
Cflags: -I\${includedir}
EOF

  mbuild dav1d "$SRC/dav1d-$DAV1D" \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false

  mbuild freetype "$SRC/freetype-$FREETYPE" \
    -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled -Dtests=disabled

  mbuild fribidi "$SRC/fribidi-$FRIBIDI" \
    -Ddocs=false -Dbin=false -Dtests=false -Ddeprecated=false

  mbuild harfbuzz "$SRC/harfbuzz-$HARFBUZZ" \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
    -Dicu=disabled -Dgraphite2=disabled -Dcoretext=disabled -Dpng=disabled -Dzlib=disabled \
    -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled

  mbuild libass "$SRC/libass-$LIBASS" \
    -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled -Dlibunibreak=disabled

  if ! done_step glslang; then
  step "$arch : glslang"
  rm -rf "$work/glslang"
  : > "$log/glslang.log"
  run "$log/glslang.log" cmake -S "$SRC/glslang-$GLSLANG" -B "$work/glslang" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" -DCMAKE_OSX_SYSROOT="$SDK" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DENABLE_GLSLANG_BINARIES=OFF \
    -DENABLE_HLSL=OFF
  run "$log/glslang.log" cmake --build "$work/glslang" -j "$JOBS"
  run "$log/glslang.log" cmake --install "$work/glslang"
  rm -rf "$work/glslang"
  touch "$prefix/.done-glslang"
  fi

  # libplacebo cherche glslang avec find_library : SPIRV dans <vulkan-sdk>/lib,
  # mais libglslang seulement dans les chemins par défaut du compilateur. Le
  # préfixe lui sert de « SDK », et la recherche de libglslang y est étendue.
  git -C "$SRC/libplacebo" checkout -- src/glsl/meson.build
  sed -i '' "s/cxx.find_library('glslang', required: required, static: static)/cxx.find_library('glslang', required: required, static: static, dirs: vulkan_lib_dirs)/" \
    "$SRC/libplacebo/src/glsl/meson.build"
  # Même chose pour glslang-default-resource-limits (GetDefaultResources), cherchée
  # avant que vulkan_lib_dirs n'existe : sans elle, le symbole manque au chargement.
  sed -i '' "s|cxx.find_library('glslang-default-resource-limits', required: false)|cxx.find_library('glslang-default-resource-limits', required: false, dirs: [get_option('vulkan-sdk') / 'lib'])|" \
    "$SRC/libplacebo/src/glsl/meson.build"

  # vk-proc-addr : mpv crée son instance Vulkan sans fournir vkGetInstanceProcAddr,
  # libplacebo doit donc le prendre lui-même — ici, dans MoltenVK lié en statique.
  mbuild libplacebo "$SRC/libplacebo" \
    -Dvulkan-sdk="$prefix" \
    -Dvulkan=enabled -Dvk-proc-addr=enabled \
    -Dvulkan-registry="$SRC/libplacebo/3rdparty/Vulkan-Headers/registry/vk.xml" \
    -Dglslang=enabled -Dshaderc=disabled -Dopengl=disabled -Dd3d11=disabled -Dlcms=disabled \
    -Ddovi=enabled -Dlibdovi=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
    -Dunwind=disabled -Dxxhash=disabled

  if ! done_step ffmpeg; then
  step "$arch : ffmpeg"
  rm -rf "$work/ffmpeg"
  : > "$log/ffmpeg.log"
  mkdir -p "$work/ffmpeg"
  (
    cd "$work/ffmpeg"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    run "$log/ffmpeg.log" "$SRC/ffmpeg-$FFMPEG/configure" \
      --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch="$family" \
      --cc="clang -arch $arch" --cxx="clang++ -arch $arch" --x86asmexe=nasm \
      --extra-cflags="-mmacosx-version-min=$MACOS_MIN -isysroot $SDK" \
      --extra-ldflags="-mmacosx-version-min=$MACOS_MIN -isysroot $SDK" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --enable-static --disable-shared --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-encoders --disable-muxers --disable-devices --disable-avdevice \
      --disable-autodetect \
      --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
      --enable-zlib --enable-bzlib --enable-iconv --enable-libdav1d
    run "$log/ffmpeg.log" make -j"$JOBS"
    run "$log/ffmpeg.log" make install
  )
  rm -rf "$work/ffmpeg"
  touch "$prefix/.done-ffmpeg"
  fi

  if ! done_step mpv; then
  step "$arch : mpv"
  rm -rf "$work/mpv"
  : > "$log/mpv.log"
  run "$log/mpv.log" meson setup "$work/mpv" "$SRC/mpv" --cross-file "$work/cross-mpv.ini" \
    --prefix "$prefix" --libdir lib --buildtype release --default-library shared -Dprefer_static=true \
    -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dbuild-date=false -Dtests=false \
    -Dcocoa=enabled -Dswift-build=enabled -Dswift-flags="-target $arch-apple-macos$MACOS_MIN" \
    -Dvulkan=enabled -Dvideotoolbox-pl=enabled -Dcoreaudio=enabled \
    -Dgl=disabled -Dgl-cocoa=disabled -Dplain-gl=disabled -Dvideotoolbox-gl=disabled \
    -Dmacos-media-player=disabled -Dmacos-touchbar=disabled -Dmacos-cocoa-cb=disabled \
    -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
    -Drubberband=disabled -Dvapoursynth=disabled -Dcdda=disabled -Ddvdnav=disabled -Ddvbin=disabled \
    -Djpeg=disabled -Dlcms2=disabled -Duchardet=disabled -Dzimg=disabled -Dlibavdevice=disabled \
    -Dshaderc=disabled -Dspirv-cross=disabled \
    -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
  run "$log/mpv.log" meson compile -C "$work/mpv"
  run "$log/mpv.log" meson install -C "$work/mpv"
  rm -rf "$work/mpv"
  touch "$prefix/.done-mpv"
  fi

  local lib="$prefix/lib/libmpv.2.dylib"
  strip -x "$lib"
  # Le binaire ne doit dépendre que du système : c'est tout le sens du build.
  local foreign
  foreign="$(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' | grep -v "libmpv" || true)"
  if [ -n "$foreign" ]; then
    echo "ÉCHEC : $arch dépend de bibliothèques hors système :" >&2
    echo "$foreign" >&2
    exit 1
  fi
  # Un symbole laissé à la résolution au chargement ne fait pas échouer le lien,
  # seulement le dlopen, chez l'utilisateur. Il doit faire échouer le build.
  local unresolved
  unresolved="$(nm -m "$lib" | grep "dynamically looked up" \
    | sed -E 's/.* external ([^ ]+) \(dynamically looked up\).*/\1/' | sort -u || true)"
  if [ -n "$unresolved" ]; then
    echo "ÉCHEC : $arch a des symboles non résolus :" >&2
    echo "$unresolved" >&2
    exit 1
  fi
}

assemble() {
  step "assemblage de OnyxMpv.xcframework"
  local fw="$ROOT/OnyxMpv.framework"
  rm -rf "$fw"
  mkdir -p "$fw/Versions/A/Resources"
  lipo -create "$ROOT/arm64/prefix/lib/libmpv.2.dylib" "$ROOT/x86_64/prefix/lib/libmpv.2.dylib" \
    -output "$fw/Versions/A/OnyxMpv"
  install_name_tool -id "@rpath/OnyxMpv.framework/Versions/A/OnyxMpv" "$fw/Versions/A/OnyxMpv"
  cat > "$fw/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>OnyxMpv</string>
  <key>CFBundleIdentifier</key><string>com.projectplayer.onyx.mpv</string>
  <key>CFBundleName</key><string>OnyxMpv</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${MPV#v}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>
</dict>
</plist>
EOF
  ln -s A "$fw/Versions/Current"
  ln -s Versions/Current/OnyxMpv "$fw/OnyxMpv"
  ln -s Versions/Current/Resources "$fw/Resources"
  codesign --force --sign - "$fw"

  rm -rf "$DEST/OnyxMpv.xcframework"
  mkdir -p "$DEST"
  xcodebuild -create-xcframework -framework "$fw" -output "$DEST/OnyxMpv.xcframework" >/dev/null
  lipo -info "$fw/Versions/A/OnyxMpv"
  du -sh "$DEST/OnyxMpv.xcframework"
}

for arch in arm64 x86_64; do
  build_arch "$arch"
done
assemble

echo
echo "OnyxMpv.xcframework : $DEST/OnyxMpv.xcframework"
