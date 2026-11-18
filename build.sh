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
  # Ask a running copy to quit normally (it asks first if exports are running), and wait for it.
  if pgrep -x Originals >/dev/null; then
    osascript -e 'tell application id "local.originals.Originals" to quit' || true
    for _ in $(seq 1 100); do pgrep -x Originals >/dev/null || break; sleep 0.1; done
    if pgrep -x Originals >/dev/null; then echo "Originals is still running; quit it, then open $APP"; exit 1; fi
  fi
  open "$APP"
fi
