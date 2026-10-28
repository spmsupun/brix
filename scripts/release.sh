#!/bin/sh
# Builds a universal, Developer ID–signed, notarised Brix.app and zips it for a
# GitHub Release.
#
#   scripts/release.sh 0.1.0-beta.2
#
# Needs the "Developer ID Application" certificate in the login keychain and a
# notarytool profile stored once with:
#   xcrun notarytool store-credentials brix-notary --apple-id <apple id> --team-id <team id>
# Override with SIGN_IDENTITY, TEAM_ID or NOTARY_PROFILE.
set -eu

VERSION="${1:?usage: scripts/release.sh <version>}"
TEAM_ID="${TEAM_ID:-6246ZNBBCA}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: SUPUN ATTANAYAKA ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-brix-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate --quiet

APP=build/release/Build/Products/Release/Brix.app
ZIP="build/dist/Brix-$VERSION-macOS.zip"
rm -rf build/release build/dist
mkdir -p build/dist

echo "Building $VERSION…"
xcodebuild -project Brix.xcodeproj -scheme Brix -configuration Release \
  -derivedDataPath build/release -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" INFOPLIST_KEY_CFBundleShortVersionString="$VERSION" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet build
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Brix/Resources/Brix.entitlements -s "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Notarising…"
ditto -c -k --keepParent "$APP" build/dist/notarize.zip
xcrun notarytool submit build/dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
rm build/dist/notarize.zip
xcrun stapler staple "$APP"
spctl -a -vv -t exec "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build/dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Ready: $ZIP"
cat "$ZIP.sha256"
echo
echo "After publishing the GitHub release, update the Homebrew cask (spmsupun/homebrew-tap, Casks/brix.rb):"
echo "  version \"$VERSION\""
echo "  sha256 \"$(cut -d' ' -f1 "$ZIP.sha256")\""
