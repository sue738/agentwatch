#!/bin/bash
# Builds AgentWatch into a .app. `swift build` alone leaves a bare executable that
# shows a Dock icon, has no bundle identifier and is unsigned; these steps were
# being done by hand and were not in the repository, so a clone could not
# reproduce the app.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="dist/AgentWatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/agentwatch "$APP/Contents/MacOS/agentwatch"
cp Info.plist "$APP/Contents/Info.plist"

cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP"

echo "==> done: $APP"
echo ""
echo "Install:"
echo "  cp -r $APP ~/Applications/"
echo "  open ~/Applications/AgentWatch.app"
echo ""
echo "Add as a login item (to keep it running):"
echo '  osascript -e '"'"'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/AgentWatch.app", hidden:false}'"'"''
