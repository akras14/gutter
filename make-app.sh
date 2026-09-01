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
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
# Signing. Unset SIGN_ID (the normal case) gives an ad-hoc signature, which
# only works on this machine: macOS keys TCC grants to the ad-hoc cdhash, so
# every rebuild re-asks for Downloads/Documents/etc. Set SIGN_ID to a
# "Developer ID Application: ..." identity (security find-identity -v
# -p codesigning) for a build others can run - that adds the hardened runtime
# and a trusted timestamp, both required by notarization.
# No --deep: the bundle has exactly one Mach-O, Contents/MacOS/Gutter.
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Gutter.entitlements \
        --sign "$SIGN_ID" "$APP"
else
    codesign --force --entitlements Gutter.entitlements --sign - "$APP"
fi

# Notarization. Needs a signed build plus credentials stored once with
#   xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...
# Stapling embeds the ticket so the app opens without a network round-trip.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${SIGN_ID:-}" ]; then
        echo "NOTARY_PROFILE set but SIGN_ID is not; ad-hoc builds cannot be notarized" >&2
        exit 1
    fi
    ditto -c -k --keepParent "$APP" dist/Gutter.zip
    xcrun notarytool submit dist/Gutter.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f dist/Gutter.zip
fi

echo "built: $APP"
