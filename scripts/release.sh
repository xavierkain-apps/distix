#!/bin/bash
# Publie une version de DistiX depuis le Mac de Xavier (comme `make publish` d'InFlow) :
#
#   scripts/release.sh 0.2.0
#
# 1. construit l'app universelle signée Developer ID (identité trouvée dans le trousseau) ;
# 2. la fait notariser (profil notarytool, par défaut celui d'InFlow) et agrafe le ticket ;
# 3. signe l'archive pour Sparkle avec la clé EdDSA du trousseau (compte par défaut, la même
#    que QuiX : sa moitié publique est dans app/sparkle-public-key.txt) ;
# 4. écrit appcast.xml, pose le tag vX.Y.Z et publie la release GitHub (zip + appcast).
#
# Les apps installées vérifient https://github.com/xavierkain-apps/distix/releases/latest/download/appcast.xml.
set -euo pipefail
VERSION="${1:?usage : scripts/release.sh X.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTES="release-notes/$VERSION.fr.md"
NOTARY_PROFILE="${NOTARY_PROFILE:-inflow-notary}"

[[ -f "$NOTES" ]] || { echo "Manque $NOTES (notes de version affichées par Sparkle)." >&2; exit 1; }
grep -q ']]>' "$NOTES" && { echo "$NOTES contient ']]>'." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Arbre git non propre : commiter d'abord." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Le tag v$VERSION existe déjà." >&2; exit 1; }

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/^.*"\(.*\)"$/\1/')
[[ -n "$IDENTITY" ]] || { echo "Aucune identité « Developer ID Application » dans le trousseau." >&2; exit 1; }
echo "Signature : $IDENTITY"

SIGN_IDENTITY="$IDENTITY" DISTIX_VERSION="$VERSION" scripts/build-app.sh
APP="$ROOT/build/DistiX.app"
[[ -n "$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")" ]] || { echo "SUPublicEDKey vide." >&2; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow présent : Apple refuserait la notarisation." >&2; exit 1
fi

echo "Notarisation (1 à 5 min)…"
ditto -c -k --keepParent "$APP" "$ROOT/build/notarize.zip"
xcrun notarytool submit "$ROOT/build/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
(cd "$ROOT/build" && rm -f DistiX.zip notarize.zip && ditto -c -k --keepParent DistiX.app DistiX.zip)

SIGN_UPDATE=$(find "$ROOT/app/.build/artifacts" -name sign_update -type f | head -1)
[[ -n "$SIGN_UPDATE" ]] || { echo "sign_update (Sparkle) introuvable." >&2; exit 1; }
SIGNATURE=$("$SIGN_UPDATE" "$ROOT/build/DistiX.zip" | sed -E 's/[[:space:]]*length="[0-9]+"//')
echo "$SIGNATURE" | grep -q 'sparkle:edSignature' || { echo "Pas de signature Sparkle." >&2; exit 1; }

BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
LENGTH=$(stat -f%z "$ROOT/build/DistiX.zip")
URL="https://github.com/xavierkain-apps/distix/releases/download/v$VERSION/DistiX.zip"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  echo '  <channel>'
  echo '    <title>DistiX</title>'
  echo '    <item>'
  echo "      <title>DistiX $VERSION</title>"
  echo "      <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
  echo "      <sparkle:version>$BUILD</sparkle:version>"
  echo "      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
  echo '      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
  echo '      <description sparkle:format="markdown"><![CDATA['
  cat "$NOTES"
  echo '      ]]></description>'
  echo "      <enclosure url=\"$URL\" length=\"$LENGTH\" type=\"application/octet-stream\" $SIGNATURE />"
  echo '    </item>'
  echo '  </channel>'
  echo '</rss>'
} > "$ROOT/build/appcast.xml"
xmllint --noout "$ROOT/build/appcast.xml"
[[ "$(grep -o ' length=' "$ROOT/build/appcast.xml" | wc -l | tr -d ' ')" == "1" ]]

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ROOT/build/DistiX.zip" "$ROOT/build/appcast.xml" \
  --repo xavierkain-apps/distix --title "DistiX $VERSION" --notes-file "$NOTES"
echo "Publiée : DistiX $VERSION (build $BUILD). Installer depuis la release, puis les mises à jour arrivent seules."
