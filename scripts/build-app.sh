#!/bin/bash
# Construit DistiX.app (universelle arm64 + x86_64) dans build/.
#
#   SIGN_IDENTITY   identité de signature (« Developer ID Application: … ») ; ad hoc si vide
#   DISTIX_VERSION  version affichée (par défaut 0.1.0 ; la CI la tire du tag v…)
#   DISTIX_ARCH     « native » pour ne construire que l'architecture de la machine
#   DISTIX_OUT      dossier de sortie (par défaut build/), pour ne pas remplacer une app ouverte
#
# Hardened Runtime activé, app non sandboxée (brief § 8). Sparkle (mises à jour) est embarqué
# dans Contents/Frameworks et ses exécutables imbriqués sont resignés avec la même identité,
# sans quoi Apple refuse la notarisation (voir QuiX, Support/sign-sparkle.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Dossier de sortie résolu depuis le dossier d'appel, avant tout cd.
OUT="${DISTIX_OUT:-$ROOT/build}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$ROOT/app"

ARCHS=(--arch arm64 --arch x86_64)
if [[ "${DISTIX_ARCH:-universal}" == "native" ]]; then ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="$OUT/DistiX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/DistiX" "$APP/Contents/MacOS/DistiX"
cp "$BIN/distix-cli" "$APP/Contents/MacOS/distix-cli"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done

# Sparkle : le framework à côté des autres, et l'exécutable qui sait l'y trouver.
SPARKLE="$(find "$BIN" "$ROOT/app/.build" -name Sparkle.framework -type d -prune 2>/dev/null | head -1)"
if [[ -z "$SPARKLE" ]]; then echo "Sparkle.framework introuvable" >&2; exit 1; fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/DistiX" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DistiX"
fi

# Icône : générée à partir de app/AppIcon.png.
if [[ -f "$ROOT/app/AppIcon.png" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/app/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/app/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="${DISTIX_VERSION:-0.1.0}"
# Clé publique des mises à jour : sans elle, l'app désactive Sparkle (constructions de dev).
SU_KEY="$(tr -d '[:space:]' < "$ROOT/app/sparkle-public-key.txt" 2>/dev/null || true)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.xavierkain.distix</string>
  <key>CFBundleName</key><string>DistiX</string>
  <key>CFBundleDisplayName</key><string>DistiX</string>
  <key>CFBundleExecutable</key><string>DistiX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Usage personnel.</string>
  <key>SUFeedURL</key><string>https://github.com/xavierkain-apps/distix/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>${SU_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
# Developer ID : Hardened Runtime et horodatage (exigés pour la notarisation).
# Ad hoc (constructions locales) : sans Hardened Runtime. Avec lui, la validation des
# bibliothèques refuse Sparkle.framework (« different Team IDs ») et l'app plante au
# lancement : une signature ad hoc n'a pas d'identifiant d'équipe.
if [[ "$IDENTITY" == "-" ]]; then
  FLAGS=(--timestamp=none)
else
  FLAGS=(--options runtime --timestamp)
fi
sign() {
  if [[ -e "$1" ]]; then
    codesign --force "${FLAGS[@]}" --preserve-metadata=entitlements --sign "$IDENTITY" "$1"
  fi
}
# Du plus profond vers le plus extérieur.
V="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
sign "$V/XPCServices/Downloader.xpc"
sign "$V/XPCServices/Installer.xpc"
sign "$V/Autoupdate"
sign "$V/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/distix-cli"
codesign --force "${FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# La vérification de signature ne prouve pas que l'app se lance : on vérifie que dyld
# charge Sparkle (le binaire s'arrête sur une option inconnue sans ouvrir de fenêtre).
if ! DYLD_PRINT_LIBRARIES=0 "$APP/Contents/MacOS/DistiX" --distix-dyld-check >/dev/null 2>"$OUT/dyld-check.log"; then
  if grep -q "Library not loaded\|not valid for use in process" "$OUT/dyld-check.log"; then
    cat "$OUT/dyld-check.log" >&2
    echo "ÉCHEC : l'app ne pourrait pas se lancer (chargement de Sparkle refusé)." >&2
    exit 1
  fi
fi
rm -f "$OUT/dyld-check.log"

cd "$OUT"
rm -f DistiX.zip
ditto -c -k --keepParent DistiX.app DistiX.zip
echo "OK : $APP (version $VERSION, build $BUILD_NUMBER, signature ${IDENTITY})"
