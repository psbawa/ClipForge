#!/bin/sh
# Archive, export with Developer ID, notarize and staple ClipForge.app.
# One-time: xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Usage: scripts/notarize.sh <notarytool-keychain-profile>
set -eu
PROFILE="${1:?usage: scripts/notarize.sh <notarytool-keychain-profile>}"
cd "$(dirname "$0")/.."
rm -rf build
xcodebuild -project "Untitled Project 2.xcodeproj" -scheme ClipForge -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/ClipForge.xcarchive archive
xcodebuild -exportArchive -archivePath build/ClipForge.xcarchive \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath build/export
ditto -c -k --keepParent build/export/ClipForge.app build/ClipForge.zip
xcrun notarytool submit build/ClipForge.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/export/ClipForge.app
spctl --assess --type execute --verbose build/export/ClipForge.app
