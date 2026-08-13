#!/usr/bin/env bash
# =============================================================================
# Onyx — build multi-plateforme (APK + EXE + DMG)
# =============================================================================
# Usage:
#   ./scripts/build-releases.sh              # builds what the host OS allows
#   ./scripts/build-releases.sh --android    # APK only
#   ./scripts/build-releases.sh --macos     # DMG only (macOS host)
#   ./scripts/build-releases.sh --windows   # EXE only (Windows host / WSL+tools)
#   ./scripts/build-releases.sh --all       # attempt every target
#
# Outputs land in:
#   dist/Onyx-<version>-<timestamp>/
#     android/Onyx-<version>.apk
#     macos/Onyx-<version>.dmg
#     windows/Onyx-<version>-Setup.exe   (or .zip if Inno Setup missing)
#     MANIFEST.txt
#
# Notes:
#   - Flutter cannot cross-compile desktop apps. Windows EXE requires a Windows
#     machine (or CI). macOS DMG requires macOS. APK builds on macOS/Linux/Windows
#     when the Android SDK is installed.
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
DIST_ROOT="${ROOT_DIR}/dist"

DO_ANDROID=0
DO_MACOS=0
DO_WINDOWS=0
MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android) DO_ANDROID=1; MODE="explicit"; shift ;;
    --macos) DO_MACOS=1; MODE="explicit"; shift ;;
    --windows) DO_WINDOWS=1; MODE="explicit"; shift ;;
    --all) DO_ANDROID=1; DO_MACOS=1; DO_WINDOWS=1; MODE="explicit"; shift ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "Option inconnue: $1" >&2
      exit 1
      ;;
  esac
done

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$HOST_OS" in
  darwin*) HOST="macos" ;;
  linux*) HOST="linux" ;;
  msys*|mingw*|cygwin*) HOST="windows" ;;
  *) HOST="unknown" ;;
esac

if [[ "$MODE" == "auto" ]]; then
  DO_ANDROID=1
  if [[ "$HOST" == "macos" ]]; then DO_MACOS=1; fi
  if [[ "$HOST" == "windows" ]]; then DO_WINDOWS=1; fi
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Erreur: flutter introuvable dans le PATH." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }
fail() { printf '    ✗ %s\n' "$*" >&2; }

# macOS /usr/bin/java is often a stub. Prefer a real JDK for Gradle.
resolve_java_home() {
  local candidate
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    if "${JAVA_HOME}/bin/java" -version >/dev/null 2>&1; then
      echo "$JAVA_HOME"
      return 0
    fi
  fi

  for candidate in \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "/Applications/Android Studio.app/Contents/jre/Contents/Home"
  do
    if [[ -x "${candidate}/bin/java" ]] && "${candidate}/bin/java" -version >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  if /usr/libexec/java_home >/dev/null 2>&1; then
    /usr/libexec/java_home
    return 0
  fi

  return 1
}

resolve_android_sdk() {
  local props sdk
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME" ]]; then
    echo "$ANDROID_HOME"
    return 0
  fi
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
    echo "$ANDROID_SDK_ROOT"
    return 0
  fi

  props="${APP_DIR}/android/local.properties"
  if [[ -f "$props" ]]; then
    sdk="$(python3 - <<'PY' "$props"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^sdk\.dir=(.+)$', text, re.M)
print(m.group(1).strip() if m else '')
PY
)"
    # local.properties may escape spaces as \:
    sdk="${sdk//\\:/:}"
    if [[ -n "$sdk" && -d "$sdk" ]]; then
      echo "$sdk"
      return 0
    fi
  fi

  for sdk in \
    "${HOME}/Library/Android/sdk" \
    "/opt/homebrew/share/android-commandlinetools" \
    "${HOME}/Android/Sdk"
  do
    if [[ -d "$sdk" ]]; then
      echo "$sdk"
      return 0
    fi
  done

  return 1
}

setup_android_toolchain() {
  local java_home sdk_home
  if ! java_home="$(resolve_java_home)"; then
    fail "Aucun JDK utilisable trouvé."
    warn "Installe OpenJDK 17 puis relance :"
    warn "  brew install openjdk@17"
    warn "Ou exporte JAVA_HOME vers ton JDK avant le script."
    return 1
  fi
  export JAVA_HOME="$java_home"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  ok "JAVA_HOME=${JAVA_HOME}"

  if ! sdk_home="$(resolve_android_sdk)"; then
    fail "Android SDK introuvable."
    warn "Installe le SDK (Android Studio) ou mets sdk.dir dans app/android/local.properties"
    return 1
  fi
  export ANDROID_HOME="$sdk_home"
  export ANDROID_SDK_ROOT="$sdk_home"
  export PATH="${ANDROID_HOME}/platform-tools:${PATH}"
  ok "ANDROID_HOME=${ANDROID_HOME}"
  return 0
}

VERSION="$(
  python3 - <<'PY' "$APP_DIR/pubspec.yaml"
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^version:\s*([^\s+]+)', text, re.M)
print(m.group(1) if m else '1.0.0')
PY
)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${DIST_ROOT}/Onyx-${VERSION}-${STAMP}"
ANDROID_OUT="${OUT_DIR}/android"
MACOS_OUT="${OUT_DIR}/macos"
WINDOWS_OUT="${OUT_DIR}/windows"
MANIFEST="${OUT_DIR}/MANIFEST.txt"

mkdir -p "$ANDROID_OUT" "$MACOS_OUT" "$WINDOWS_OUT"

{
  echo "Onyx release build"
  echo "version: ${VERSION}"
  echo "stamp: ${STAMP}"
  echo "host: ${HOST} ($(uname -a))"
  echo "flutter: $(flutter --version 2>/dev/null | head -1)"
  echo "started: $(date -Iseconds 2>/dev/null || date)"
  echo
} > "$MANIFEST"

cd "$APP_DIR"
log "flutter pub get"
flutter pub get

BUILT_ANY=0
FAILED_ANY=0

# -----------------------------------------------------------------------------
# Android APK
# -----------------------------------------------------------------------------
if [[ "$DO_ANDROID" -eq 1 ]]; then
  log "Build Android APK"
  if setup_android_toolchain; then
    echo "java_home: ${JAVA_HOME}" >> "$MANIFEST"
    echo "android_home: ${ANDROID_HOME}" >> "$MANIFEST"
    if flutter build apk --release; then
      APK_SRC="${APP_DIR}/build/app/outputs/flutter-apk/app-release.apk"
      if [[ ! -f "$APK_SRC" ]]; then
        APK_SRC="$(find "${APP_DIR}/build" -name 'app-release.apk' | head -1 || true)"
      fi
      if [[ -n "${APK_SRC}" && -f "$APK_SRC" ]]; then
        APK_DST="${ANDROID_OUT}/Onyx-${VERSION}.apk"
        cp "$APK_SRC" "$APK_DST"
        cp "$APK_SRC" "${ANDROID_OUT}/app-release.apk"
        ok "APK → ${APK_DST}"
        echo "android: ${APK_DST}" >> "$MANIFEST"
        BUILT_ANY=1
      else
        fail "APK généré introuvable"
        echo "android: FAILED (artifact missing)" >> "$MANIFEST"
        FAILED_ANY=1
      fi
    else
      fail "flutter build apk a échoué"
      echo "android: FAILED (build)" >> "$MANIFEST"
      FAILED_ANY=1
    fi
  else
    echo "android: FAILED (JDK or Android SDK missing)" >> "$MANIFEST"
    FAILED_ANY=1
  fi
else
  echo "android: skipped" >> "$MANIFEST"
fi

# -----------------------------------------------------------------------------
# macOS → DMG
# -----------------------------------------------------------------------------
if [[ "$DO_MACOS" -eq 1 ]]; then
  log "Build macOS + package DMG"
  if [[ "$HOST" != "macos" ]]; then
    warn "DMG impossible hors macOS — skip"
    echo "macos: SKIPPED (host is not macOS)" >> "$MANIFEST"
  else
    if flutter build macos --release; then
      APP_BUNDLE="$(find "${APP_DIR}/build/macos" -maxdepth 5 -name '*.app' -type d | head -1 || true)"
      if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
        fail "Bundle .app introuvable"
        echo "macos: FAILED (app missing)" >> "$MANIFEST"
        FAILED_ANY=1
      else
        STAGE="${OUT_DIR}/.dmg-stage"
        rm -rf "$STAGE"
        mkdir -p "$STAGE"
        # Rename for nicer Finder volume contents
        cp -R "$APP_BUNDLE" "${STAGE}/Onyx.app"
        # Optional Applications shortcut
        ln -sf /Applications "${STAGE}/Applications"

        DMG_PATH="${MACOS_OUT}/Onyx-${VERSION}.dmg"
        rm -f "$DMG_PATH"
        hdiutil create \
          -volname "Onyx ${VERSION}" \
          -srcfolder "$STAGE" \
          -ov \
          -format UDZO \
          "$DMG_PATH" >/dev/null

        rm -rf "$STAGE"
        # Keep a copy of the raw .app too
        cp -R "$APP_BUNDLE" "${MACOS_OUT}/Onyx.app"
        ok "DMG → ${DMG_PATH}"
        echo "macos: ${DMG_PATH}" >> "$MANIFEST"
        BUILT_ANY=1
      fi
    else
      fail "flutter build macos a échoué"
      echo "macos: FAILED (build)" >> "$MANIFEST"
      FAILED_ANY=1
    fi
  fi
else
  echo "macos: skipped" >> "$MANIFEST"
fi

# -----------------------------------------------------------------------------
# Windows → EXE (Inno Setup installer if available, else zip)
# -----------------------------------------------------------------------------
if [[ "$DO_WINDOWS" -eq 1 ]]; then
  log "Build Windows EXE"
  if [[ "$HOST" != "windows" ]]; then
    warn "EXE Windows impossible hors Windows — skip"
    warn "Relancez ce script sur une machine Windows, ou utilisez scripts/build-releases.ps1"
    echo "windows: SKIPPED (host is not Windows — Flutter cannot cross-compile desktop)" >> "$MANIFEST"
  else
    export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"
    if flutter build windows --release; then
      WIN_RELEASE="${APP_DIR}/build/windows/x64/runner/Release"
      if [[ ! -d "$WIN_RELEASE" ]]; then
        WIN_RELEASE="$(find "${APP_DIR}/build/windows" -type d -name Release | head -1 || true)"
      fi
      if [[ -z "${WIN_RELEASE}" || ! -d "$WIN_RELEASE" ]]; then
        fail "Dossier Release Windows introuvable"
        echo "windows: FAILED (release dir missing)" >> "$MANIFEST"
        FAILED_ANY=1
      else
        ZIP_PATH="${WINDOWS_OUT}/Onyx-${VERSION}-windows-x64.zip"
        if command -v powershell.exe >/dev/null 2>&1; then
          powershell.exe -NoProfile -Command \
            "Compress-Archive -Path '$(cygpath -w "$WIN_RELEASE" 2>/dev/null || echo "$WIN_RELEASE")\\*' -DestinationPath '$(cygpath -w "$ZIP_PATH" 2>/dev/null || echo "$ZIP_PATH")' -Force" \
            || (cd "$WIN_RELEASE" && zip -r "$ZIP_PATH" .)
        elif command -v zip >/dev/null 2>&1; then
          (cd "$WIN_RELEASE" && zip -r "$ZIP_PATH" .)
        else
          cp -R "$WIN_RELEASE" "${WINDOWS_OUT}/Onyx-${VERSION}-portable"
          ZIP_PATH="${WINDOWS_OUT}/Onyx-${VERSION}-portable"
        fi
        ok "Windows binaries → ${ZIP_PATH}"

        # Inno Setup (installer.iss) if ISCC is available
        if command -v iscc >/dev/null 2>&1 || command -v ISCC.exe >/dev/null 2>&1; then
          ISCC_BIN="$(command -v iscc || command -v ISCC.exe)"
          ISS="${APP_DIR}/installer.iss"
          if [[ -f "$ISS" ]]; then
            "$ISCC_BIN" "$ISS" || true
            SETUP_SRC="${APP_DIR}/Output/Onyx-Setup.exe"
            if [[ -f "$SETUP_SRC" ]]; then
              SETUP_DST="${WINDOWS_OUT}/Onyx-${VERSION}-Setup.exe"
              cp "$SETUP_SRC" "$SETUP_DST"
              ok "Installer → ${SETUP_DST}"
              echo "windows: ${SETUP_DST}" >> "$MANIFEST"
            else
              echo "windows: ${ZIP_PATH} (installer not produced)" >> "$MANIFEST"
            fi
          else
            echo "windows: ${ZIP_PATH}" >> "$MANIFEST"
          fi
        else
          echo "windows: ${ZIP_PATH}" >> "$MANIFEST"
          warn "Inno Setup (iscc) absent — ZIP portable uniquement"
        fi
        BUILT_ANY=1
      fi
    else
      fail "flutter build windows a échoué"
      echo "windows: FAILED (build)" >> "$MANIFEST"
      FAILED_ANY=1
    fi
  fi
else
  echo "windows: skipped" >> "$MANIFEST"
fi

{
  echo
  echo "finished: $(date -Iseconds 2>/dev/null || date)"
  echo "output_dir: ${OUT_DIR}"
} >> "$MANIFEST"

# Convenience: latest symlink
ln -sfn "$(basename "$OUT_DIR")" "${DIST_ROOT}/latest"

log "Terminé"
echo "Dossier: ${OUT_DIR}"
echo
find "$OUT_DIR" -maxdepth 2 \( -type f -o -type d \) ! -path '*/.dmg-stage*' | sort
echo
cat "$MANIFEST"

if [[ "$BUILT_ANY" -eq 0 ]]; then
  fail "Aucun artefact produit"
  exit 1
fi

if [[ "$FAILED_ANY" -eq 1 ]]; then
  warn "Certaines cibles ont échoué — voir MANIFEST.txt"
  exit 2
fi

exit 0
