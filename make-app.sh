#!/bin/bash
# Assembles dist/Gutter.app from the built binary + Info.plist and
# ad-hoc signs it. The app must be run as a bundle (not the bare binary).
set -euo pipefail
cd "$(dirname "$0")"

[ -x bin/Gutter ] || ./build.sh

APP=dist/Gutter.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp bin/Gutter "$APP/Contents/MacOS/Gutter"

# Bundle ghostty's resources (themes, shell-integration, terminfo) like the
# official app does (Resources/ghostty/...); libghostty resolves them via
# GHOSTTY_RESOURCES_DIR. Shell integration drives tab titles.
# Vendored deps/share is preferred; GHOSTTY (checkout) is the fallback.
GHOSTTY=${GHOSTTY:-$HOME/projects/ak/ghostty}
RES_SRC=deps/share
[ -d "$RES_SRC/ghostty" ] || RES_SRC="$GHOSTTY/zig-out/share"
if [ -d "$RES_SRC/ghostty" ]; then
    mkdir -p "$APP/Contents/Resources/ghostty"
    cp -R "$RES_SRC/ghostty/" "$APP/Contents/Resources/ghostty/"
fi
# The core sets TERMINFO=dirname(GHOSTTY_RESOURCES_DIR)/terminfo and
# TERM=xterm-ghostty for every spawned shell; without the bundled entry
# (and no system fallback) shells get a broken terminfo - e.g. zsh zle
# can't erase chars on backspace.
if [ -d "$RES_SRC/terminfo" ]; then
    cp -R "$RES_SRC/terminfo" "$APP/Contents/Resources/terminfo"
fi
codesign --force --sign - "$APP"
echo "built: $APP"
