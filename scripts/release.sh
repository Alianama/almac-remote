#!/bin/bash
# scripts/release.sh <release-notes.md>
# Package (scripts/package-dmg.sh), then add what in-app updates need
# (App/Updater.swift): a zip of the .app, almac-update.json (version + size +
# SHA-512 per arch) and its Ed25519 signature, and publish a GitHub Release.
#
# Private key: $ALMAC_UPDATE_KEY or ~/.almac/update-key.pem — the same key as
# Almac Browser. NEVER commit it; keep a backup: without it installed apps can
# no longer accept updates.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=${1:-}
[[ -f "$NOTES" ]] || { echo "usage: scripts/release.sh <release-notes.md>" >&2; exit 1; }
KEY=${ALMAC_UPDATE_KEY:-$HOME/.almac/update-key.pem}
[[ -f "$KEY" ]] || { echo "missing signing key $KEY" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit your changes first" >&2; exit 1; }

VERSION=$(grep 'MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')
ARCH=$(uname -m) # Release links Homebrew FreeRDP, so the build is this Mac's arch only
DIST=".dist"
ZIP="AlmacRemote-v$VERSION-$ARCH.zip"

scripts/package-dmg.sh

rm -f "$DIST/$ZIP"
ditto -c -k --keepParent "$DIST/Almac Remote.app" "$DIST/$ZIP"
SIZE=$(stat -f%z "$DIST/$ZIP")
SHA=$(openssl dgst -sha512 -binary "$DIST/$ZIP" | base64)
printf '{\n  "app": "almac-remote",\n  "version": "%s",\n  "files": {\n    "%s": { "name": "%s", "size": %s, "sha512": "%s" }\n  }\n}\n' \
  "$VERSION" "$ARCH" "$ZIP" "$SIZE" "$SHA" > "$DIST/almac-update.json"
openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$DIST/almac-update.json" | base64 > "$DIST/almac-update.json.sig"

# Same check the app does, against the public key it ships with.
PUB=$(mktemp)
printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAXxYynRD5E9YcHDGEK5YOBMwCt0UJPvmoLwSsIsMzsQg=\n-----END PUBLIC KEY-----\n' > "$PUB"
base64 -d -i "$DIST/almac-update.json.sig" > "$PUB.sig"
openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$DIST/almac-update.json" -sigfile "$PUB.sig" >/dev/null \
  || { echo "signature does not match the public key in App/Updater.swift" >&2; exit 1; }
rm -f "$PUB" "$PUB.sig"

BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')
git push origin HEAD
gh release create "v$VERSION" --target main --title "v$VERSION (build $BUILD)" --notes-file "$NOTES" \
  "$DIST/AlmacRemote-v$VERSION.dmg" "$DIST/$ZIP" "$DIST/almac-update.json" "$DIST/almac-update.json.sig"
