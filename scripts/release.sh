#!/usr/bin/env bash
# Bumps CFBundleVersion + MARKETING_VERSION, archives, notarizes, installs to
# /Applications, writes dist/<version>/{Spokium.app, Spokium.zip, dSYMs}, then commits
# the version bump and tags v<version>. Never pushes.
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
# Versions live in Version.xcconfig (project.yml / XcodeGen); the project reads them from there.
VERSION_FILE="$REPO_ROOT/Spokium/Version.xcconfig"
SCHEME="Spokium"
KEYCHAIN_PROFILE="spokium-notary"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist/$VERSION"

if [ -d "$DIST_DIR" ]; then
    echo "dist/$VERSION already exists. Refusing to overwrite."
    exit 1
fi

# A release must match a commit: 1.5.2 was once built from uncommitted changes.
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo "Uncommitted changes — commit or stash them first:"
    git -C "$REPO_ROOT" status --short
    exit 1
fi
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "Tag v$VERSION already exists."
    exit 1
fi

echo "Running tests…"
"$REPO_ROOT/scripts/check.sh" --tests

CURRENT=$(grep -E "^CURRENT_PROJECT_VERSION = [0-9]+$" "$VERSION_FILE" | sed -E 's/.*= ([0-9]+)$/\1/')
NEW=$((CURRENT + 1))
echo "Bumping CURRENT_PROJECT_VERSION: $CURRENT -> $NEW"
echo "Setting MARKETING_VERSION: $VERSION"
sed -i '' -E "s/^CURRENT_PROJECT_VERSION = [0-9]+$/CURRENT_PROJECT_VERSION = $NEW/" "$VERSION_FILE"
sed -i '' -E "s/^MARKETING_VERSION = .*$/MARKETING_VERSION = $VERSION/" "$VERSION_FILE"

# Undo the bump if anything below fails, so the next run isn't blocked by a dirty tree.
RELEASED=no
trap '[ "$RELEASED" = yes ] || git -C "$REPO_ROOT" checkout -- "$VERSION_FILE"' EXIT

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
# Kept per release: without them crash reports from this version can't be symbolicated
# (build/ is wiped at the start of every release).
cp -R "$ARCHIVE/dSYMs" "$DIST_DIR/dSYMs"

git -C "$REPO_ROOT" commit -q -m "Release $VERSION (build $NEW)" -- "$VERSION_FILE"
git -C "$REPO_ROOT" tag -a "v$VERSION" -m "Spokium $VERSION (build $NEW)"
RELEASED=yes

# Replace the installed app without cutting off a dictation: ask the running copy to
# quit when idle (1.5.2+ waits until nothing is recorded, transcribed or pasted), then
# swap the bundle and relaunch. Older versions don't know the request and get a plain quit.
INSTALLED="/Applications/Spokium.app"
WAS_RUNNING=no
if pgrep -f "$INSTALLED/Contents/MacOS/Spokium" >/dev/null; then
    WAS_RUNNING=yes
    RUNNING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo 0)
    if [ "$(printf '%s\n1.5.2\n' "$RUNNING_VERSION" | sort -V | head -1)" = "1.5.2" ]; then
        echo "Asking Spokium $RUNNING_VERSION to quit when idle (finish your dictation)…"
        osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.spokium.mac.quitWhenIdle", $(), $(), true)' >/dev/null
    else
        echo "Quitting Spokium $RUNNING_VERSION (too old to wait for an idle moment)…"
        osascript -e 'quit app id "com.spokium.mac"' >/dev/null 2>&1 || true
    fi
    while pgrep -f "$INSTALLED/Contents/MacOS/Spokium" >/dev/null; do sleep 1; done
fi

echo "Installing to /Applications…"
rm -rf "$INSTALLED"
cp -R "$DIST_DIR/Spokium.app" "$INSTALLED"
if [ "$WAS_RUNNING" = yes ]; then
    echo "Relaunching Spokium…"
    open "$INSTALLED"
fi

echo "Done. Release $VERSION (build $NEW) installed, archived in dist/$VERSION, committed and tagged v$VERSION."
echo "Not pushed: git push && git push origin v$VERSION, then upload dist/$VERSION/Spokium.zip to the GitHub release."
