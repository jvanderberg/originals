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
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
grep -q photos-library <<<"$ENTITLEMENTS" || { echo "Missing the Photos entitlement" >&2; exit 1; }
if grep -q get-task-allow <<<"$ENTITLEMENTS"; then echo "Has get-task-allow, which notarization rejects" >&2; exit 1; fi

# Submits to Apple's notary service and waits; on anything but Accepted, prints Apple's log and fails.
notarize() {
  local result id status
  result="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json)"
  echo "$result"
  id="$(plutil -extract id raw - <<<"$result")"
  status="$(plutil -extract status raw - <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization of $1 came back $status. Apple's log:" >&2
    xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    exit 1
  fi
}

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$WORK/Originals.zip"
notarize "$WORK/Originals.zip"
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
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
