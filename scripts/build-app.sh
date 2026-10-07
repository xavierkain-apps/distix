#!/bin/bash
# Construit DistiX.app (universelle arm64 + x86_64) dans build/, signée ad hoc par
# défaut, ou avec l'identité donnée dans SIGN_IDENTITY (« Developer ID Application: … »).
# Hardened Runtime activé, app non sandboxée (brief § 8).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

ARCHS=(--arch arm64 --arch x86_64)
if [[ "${DISTIX_ARCH:-universal}" == "native" ]]; then ARCHS=(); fi
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="$ROOT/build/DistiX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DistiX" "$APP/Contents/MacOS/DistiX"
cp "$BIN/distix-cli" "$APP/Contents/MacOS/distix-cli"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
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
VERSION="0.1.0"
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
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/distix-cli"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

cd "$ROOT/build"
rm -f DistiX.zip
ditto -c -k --keepParent DistiX.app DistiX.zip
echo "OK : $APP (build $BUILD_NUMBER)"
