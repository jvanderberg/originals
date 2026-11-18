#!/bin/bash
# Builds Originals.app for distribution: Developer ID signed, notarized and stapled, inside a
# notarized and stapled DMG, so it opens on any Mac without Gatekeeper warnings.
#
#   scripts/build-release.sh [VERSION]
#
# Notarization credentials come from NOTARY_APPLE_ID / NOTARY_PASSWORD (an app-specific password)
# / NOTARY_TEAM_ID, or from a notarytool keychain profile named in NOTARY_PROFILE.
# Output: dist/Originals-VERSION.dmg and its .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2}' project.yml)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
if [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "Set NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID or NOTARY_PROFILE" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcodegen generate --quiet
xcodebuild -project Originals.xcodeproj -scheme Originals -configuration Release \
  -derivedDataPath build/release -destination 'generic/platform=macOS' -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build
APP="build/release/Build/Products/Release/Originals.app"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" | grep -q photos-library

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$WORK/Originals.zip"
xcrun notarytool submit "$WORK/Originals.zip" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Building the DMG…"
mkdir -p dist "$WORK/dmg"
DMG="dist/Originals-$VERSION.dmg"
rm -f "$DMG"
ditto "$APP" "$WORK/dmg/Originals.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Originals $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing the DMG…"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
