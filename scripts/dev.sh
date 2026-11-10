#!/usr/bin/env bash
# Bumps CFBundleVersion, archives, notarizes, installs to /Applications.
# One-time setup:
#   xcrun notarytool store-credentials spokium-notary \
#       --apple-id <your-apple-id> --team-id 6J9C6FCCS5 --password <app-specific-password>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Spokium/Spokium.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="Spokium"
KEYCHAIN_PROFILE="spokium-notary"
BUILD_DIR="$REPO_ROOT/build"

CURRENT=$(grep -m1 -E "CURRENT_PROJECT_VERSION = [0-9]+;" "$PBXPROJ" | sed -E 's/.*= ([0-9]+);.*/\1/')
NEW=$((CURRENT + 1))
echo "Bumping CURRENT_PROJECT_VERSION: $CURRENT -> $NEW"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEW;/g" "$PBXPROJ"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/Spokium.xcarchive"

echo "Archiving…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" archive

echo "Exporting…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$REPO_ROOT/scripts/ExportOptions.plist"

APP="$BUILD_DIR/export/Spokium.app"
ZIP="$BUILD_DIR/Spokium.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Notarizing…"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"

echo "Installing to /Applications…"
rm -rf "/Applications/Spokium.app"
cp -R "$APP" "/Applications/Spokium.app"

echo "Done. Build $NEW installed."
