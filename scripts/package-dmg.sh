#!/bin/bash
# Build a Release .app, bundle its third-party dylibs, and pack a DMG with an
# Applications shortcut into .dist/. Run from the repo root.
#
# Codifies steps learned the hard way while shipping v0.14.1:
# - Release links FreeRDP/OpenSSL by absolute /opt/homebrew path and never
#   embeds them -> app is a few MB and dyld can't find them elsewhere.
# - dylibbundler leaves a duplicate LC_RPATH behind -> dyld refuses to load
#   the binary at all ("duplicate LC_RPATH").
# - Hardened Runtime's Library Validation then rejects the bundled ad-hoc
#   signed dylibs ("different Team IDs") unless the app carries
#   com.apple.security.cs.disable-library-validation (App/AlmacRemote.entitlements).
# - A DMG with just the .app has no Applications shortcut to drag onto.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep 'MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')
APP=".build-release/Build/Products/Release/Almac Remote.app"
DIST=".dist"
DMG="$DIST/AlmacRemote-v$VERSION.dmg"

xcodegen generate
rm -rf .build-release
xcodebuild -project AlmacRemote.xcodeproj -scheme AlmacRemote -configuration Release -derivedDataPath .build-release build

dylibbundler -od -b \
  -x "$APP/Contents/MacOS/Almac Remote" \
  -d "$APP/Contents/Frameworks" \
  -p "@executable_path/../Frameworks"

# dylibbundler always leaves the pre-existing @executable_path/../Frameworks
# rpath duplicated; a second copy makes dyld refuse to load the binary.
install_name_tool -delete_rpath "@executable_path/../Frameworks/" "$APP/Contents/MacOS/Almac Remote"

codesign --force --deep -o runtime --timestamp=none \
  --entitlements App/AlmacRemote.entitlements --sign - "$APP"
codesign -vv --deep-verify "$APP"

# Sanity check: actually launch it before packaging, don't just trust codesign.
"$APP/Contents/MacOS/Almac Remote" >/tmp/almac-launch-check.log 2>&1 &
PID=$!
sleep 3
if ! kill -0 $PID 2>/dev/null; then
  echo "App failed to launch, see /tmp/almac-launch-check.log" >&2
  cat /tmp/almac-launch-check.log >&2
  exit 1
fi
kill $PID

rm -rf "$DIST/Almac Remote.app" "$DMG" "$DIST/dmg-staging"
mkdir -p "$DIST/dmg-staging"
cp -R "$APP" "$DIST/dmg-staging/"
ln -s /Applications "$DIST/dmg-staging/Applications"
cp -R "$APP" "$DIST/"
hdiutil create -volname "Almac Remote $VERSION" -srcfolder "$DIST/dmg-staging" -ov -format UDZO "$DMG"
rm -rf "$DIST/dmg-staging"

echo "Packaged $DMG"
