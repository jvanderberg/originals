#!/bin/bash
# Generate the Xcode project and build Originals.app.
#   ./build.sh            Debug build
#   CONFIG=Release ./build.sh
#   ./build.sh --run      build, then launch
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${CONFIG:-Debug}"
xcodegen generate --quiet
xcodebuild -project Originals.xcodeproj -scheme Originals -configuration "$CONFIG" \
  -derivedDataPath build -destination 'platform=macOS' -quiet build
APP="build/Build/Products/$CONFIG/Originals.app"
echo "Built $APP"
if [[ "${1:-}" == "--run" ]]; then
  # Ask the running copy of this build to quit normally (it asks first if exports are running), and
  # wait for it. Only this build's copy: an installed release has a different bundle ID.
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  EXECUTABLE="$PWD/$APP/Contents/MacOS/Originals"
  if pgrep -f "^$EXECUTABLE" >/dev/null; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
    for _ in $(seq 1 100); do pgrep -f "^$EXECUTABLE" >/dev/null || break; sleep 0.1; done
    if pgrep -f "^$EXECUTABLE" >/dev/null; then echo "$APP is still running; quit it, then open it again"; exit 1; fi
  fi
  open "$APP"
fi
