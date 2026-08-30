#!/bin/bash
# Assembles dist/GhosttyTabs.app from the built binary + Info.plist and
# ad-hoc signs it. The app must be run as a bundle (not the bare binary).
set -euo pipefail
cd "$(dirname "$0")"

[ -x bin/GhosttyTabs ] || ./build.sh

APP=dist/GhosttyTabs.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp bin/GhosttyTabs "$APP/Contents/MacOS/GhosttyTabs"

# Bundle ghostty's resources (themes, shell-integration, terminfo) like the
# official app does (Resources/ghostty/...); libghostty resolves them via
# GHOSTTY_RESOURCES_DIR. Shell integration drives tab titles.
GHOSTTY=${GHOSTTY:-/Users/alex.kras/projects/ak/ghostty}
if [ -d "$GHOSTTY/zig-out/share/ghostty" ]; then
    mkdir -p "$APP/Contents/Resources/ghostty"
    cp -R "$GHOSTTY/zig-out/share/ghostty/" "$APP/Contents/Resources/ghostty/"
fi
codesign --force --sign - "$APP"
echo "built: $APP"
