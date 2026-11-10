#!/usr/bin/env bash
# Bumps CFBundleVersion + MARKETING_VERSION, archives, notarizes,
# installs to /Applications, and writes dist/<version>/{Spokium.app, Spokium.zip}.
#
# Usage: ./scripts/release.sh 1.2.4
#
# One-time setup:
#   xcrun notarytool store-credentials spokium-notary \
#       --apple-id <your-apple-id> --team-id 6J9C6FCCS5 --password <app-specific-password>
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <marketing-version>"
    exit 1
fi
VERSION="$1"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/Spokium/Spokium.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="Spokium"
KEYCHAIN_PROFILE="spokium-notary"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist/$VERSION"

if [ -d "$DIST_DIR" ]; then
    echo "dist/$VERSION already exists. Refusing to overwrite."
    exit 1
fi

echo "Running tests…"
"$REPO_ROOT/scripts/check.sh" --tests

CURRENT=$(grep -m1 -E "CURRENT_PROJECT_VERSION = [0-9]+;" "$PBXPROJ" | sed -E 's/.*= ([0-9]+);.*/\1/')
NEW=$((CURRENT + 1))
echo "Bumping CURRENT_PROJECT_VERSION: $CURRENT -> $NEW"
echo "Setting MARKETING_VERSION: $VERSION"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEW;/g" "$PBXPROJ"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"

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

echo "Checking the notarized app…"
"$REPO_ROOT/scripts/check.sh" "$APP"

mkdir -p "$DIST_DIR"
cp -R "$APP" "$DIST_DIR/Spokium.app"
ditto -c -k --keepParent "$DIST_DIR/Spokium.app" "$DIST_DIR/Spokium.zip"

echo "Installing to /Applications…"
rm -rf "/Applications/Spokium.app"
cp -R "$DIST_DIR/Spokium.app" "/Applications/Spokium.app"

echo "Done. Release $VERSION (build $NEW) installed and archived in dist/$VERSION."
