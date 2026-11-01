#!/bin/sh
# Builds a universal, Developer ID–signed, notarised Brix.app, then a notarised
# disk image (open it, drag Brix to Applications), a zip for Homebrew and for
# in-app updates, and appcast.xml, the Sparkle feed for the zip.
#
#   scripts/release.sh 0.1.0-beta.2 [release-notes.md]
#
# The release notes (Markdown: plain lines, "- " bullets) go into the feed and
# show in the update window. The zip is signed with the Sparkle key that
# generate_keys keeps in the login keychain; back it up with
#   build/spm/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-key.txt
# Without it, installed copies can't take updates from new releases.
#
# Needs the "Developer ID Application" certificate in the login keychain and a
# notarytool profile stored once with:
#   xcrun notarytool store-credentials brix-notary --apple-id <apple id> --team-id <team id>
# Override with SIGN_IDENTITY, TEAM_ID or NOTARY_PROFILE.
set -eu

VERSION="${1:?usage: scripts/release.sh <version> [release-notes.md]}"
NOTES="${2:-}"
[ -z "$NOTES" ] || [ -r "$NOTES" ] || { echo "Can't read release notes: $NOTES" >&2; exit 1; }
TEAM_ID="${TEAM_ID:-6246ZNBBCA}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: SUPUN ATTANAYAKA ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-brix-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate --quiet

APP=build/release/Build/Products/Release/Brix.app
# Sparkle installs an update only when its build number is higher, so it must
# grow with every release: the commit count on this branch does.
BUILD="$(git rev-list --count HEAD)"
SPARKLE_BIN=build/spm/artifacts/sparkle/Sparkle/bin
FEED=https://github.com/spmsupun/brix/releases/latest/download/appcast.xml
# Installed copies compare against the feed that's live now; a lower or equal
# build number (another branch, a rewritten history) would offer them nothing.
PREV="$(curl -fsL "$FEED" 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1)"
if [ -n "$PREV" ] && [ "$BUILD" -le "$PREV" ]; then
  echo "Build number $BUILD is not above the published $PREV: release from the branch that made it." >&2; exit 1
fi
ZIP="build/dist/Brix-$VERSION-macOS.zip"
rm -rf build/release
mkdir -p build/dist

echo "Building ${VERSION}..."
xcodebuild -project Brix.xcodeproj -scheme Brix -configuration Release \
  -derivedDataPath build/release -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" INFOPLIST_KEY_CFBundleShortVersionString="$VERSION" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet build
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Sparkle's helpers, inside out, each with the hardened runtime notarisation needs.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for part in "$SP/XPCServices/Installer.xpc" "$SP/XPCServices/Downloader.xpc" "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements -s "$SIGN_IDENTITY" "$part"
done
codesign --force --options runtime --timestamp --entitlements Brix/Resources/Brix.entitlements -s "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Notarising..."
ditto -c -k --keepParent "$APP" build/dist/notarize.zip
xcrun notarytool submit build/dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
rm build/dist/notarize.zip
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Writing the update feed..."
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
case "$SIGNATURE" in *edSignature=*) ;; *) echo "sign_update gave no signature: $SIGNATURE" >&2; exit 1 ;; esac
HTML=""
if [ -n "$NOTES" ]; then
  # Blank lines dropped, "- x" a list item, any other line a heading or paragraph.
  HTML="$(awk '
    /^[[:space:]]*$/ { next }
    { gsub(/&/, "\\&amp;"); gsub(/</, "\\&lt;"); gsub(/>/, "\\&gt;") }
    /^- / { if (!ul) { print "<ul>"; ul = 1 } sub(/^- /, ""); print "<li>" $0 "</li>"; next }
    { if (ul) { print "</ul>"; ul = 0 } print "<p><b>" $0 "</b></p>" }
    END { if (ul) print "</ul>" }' "$NOTES" | sed 's/`\([^`]*\)`/<code>\1<\/code>/g')"
fi
cat > build/dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Brix</title>
    <item>
      <title>Brix $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$HTML]]></description>
      <enclosure url="https://github.com/spmsupun/brix/releases/download/v$VERSION/$(basename "$ZIP")" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout build/dist/appcast.xml

echo "Making the disk image..."
DMG="build/dist/Brix-$VERSION.dmg"
rm -rf build/dmg && mkdir -p build/dmg
ditto "$APP" build/dmg/Brix.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Brix $VERSION" -srcfolder build/dmg -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
rm -rf build/dmg

(cd build/dist && for f in "$(basename "$DMG")" "$(basename "$ZIP")"; do shasum -a 256 "$f" > "$f.sha256"; done)
echo "Ready: $DMG (for people), $ZIP (for Homebrew and updates) and build/dist/appcast.xml"
cat build/dist/*.sha256
echo
echo "Attach all three to a GitHub release tagged v$VERSION and mark it Latest: the app reads"
echo "releases/latest/download/appcast.xml, so a pre-release or a missing feed means no update."
echo
echo "After publishing the GitHub release, update the Homebrew cask (spmsupun/homebrew-tap, Casks/brix.rb):"
echo "  version \"$VERSION\""
echo "  sha256 \"$(cut -d' ' -f1 "$ZIP.sha256")\""
