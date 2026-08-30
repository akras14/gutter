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
# The core sets TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo and
# TERM=xterm-ghostty for every spawned shell; without the bundled entry
# (and no system fallback) shells get a broken terminfo - e.g. zsh zle
# can't erase chars on backspace.
if [ -d "$GHOSTTY/zig-out/share/terminfo" ]; then
    cp -R "$GHOSTTY/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"
fi
codesign --force --sign - "$APP"
echo "built: $APP"
