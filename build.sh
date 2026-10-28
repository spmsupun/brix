#!/bin/sh
# Builds Brix from the command line. Usage: ./build.sh [build|test]
set -e
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")"
command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project Brix.xcodeproj -scheme Brix -configuration Debug \
  -derivedDataPath "${DD:-build/dd}" -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation "${1:-build}"
