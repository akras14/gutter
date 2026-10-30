#!/bin/bash
# Assembles dist/Gutter.app from the built binary + Info.plist and
# signs it (see Signing below). The app must be run as a bundle (not the bare binary).
# Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

[ -x bin/Gutter ] || ./build.sh

APP=dist/Gutter.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# Stamp the build so About Gutter can say exactly what's running. The build
# number is the commit count (it only goes up on master), the commit is the
# short hash, marked -dirty when the tree had uncommitted changes, and the
# ghostty version is the release deps/ was built from. CFBundleShortVersionString
# stays hand-set in Info.plist. Must happen before signing, which seals it.
if git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD=$(git rev-list --count HEAD)
    COMMIT=$(git rev-parse --short HEAD)
    [ -n "$(git status --porcelain)" ] && COMMIT="$COMMIT-dirty"
else
    BUILD=0 COMMIT=unknown
fi
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :GutterCommit string $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :GutterGhosttyVersion string $(cut -d' ' -f1 deps/GHOSTTY_VERSION)" "$PLIST"
cp bin/Gutter "$APP/Contents/MacOS/Gutter"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle ghostty's resources (themes, shell-integration, terminfo) like the
# official app does (Resources/ghostty/...); libghostty resolves them via
# GHOSTTY_RESOURCES_DIR. Shell integration drives tab titles.
# Vendored deps/share is preferred; GHOSTTY (checkout) is the fallback.
GHOSTTY=${GHOSTTY:-${GUTTER_GHOSTTY_CACHE:-$HOME/.cache/gutter-ghostty}/ghostty}
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
# Signing, three ways:
# - SIGN_ID set: a "Developer ID Application: ..." identity (security
#   find-identity -v -p codesigning) for a build others can run. Adds the
#   hardened runtime and a trusted timestamp, both required by notarization.
# - Otherwise, a self-signed "Gutter Dev" code signing certificate if the
#   keychain has one (one-time setup in BUILDING.html). macOS keys TCC grants
#   to the designated requirement, and a certificate's stays the same across
#   rebuilds, so Full Disk Access, Downloads, Documents etc. survive one (#7).
#   Matched without -v: a self-signed certificate is never "valid" to
#   find-identity, but codesign signs with it all the same. Signed by hash,
#   so two certificates with the same name don't make codesign refuse.
# - Otherwise ad-hoc. That only works on this machine, and the grant is keyed
#   to the build's cdhash, so every rebuild is a new app to TCC: grants show
#   ON in System Settings and are silently refused.
# No --deep: the bundle has exactly one Mach-O, Contents/MacOS/Gutter.
LOCAL_SIGN_NAME=${LOCAL_SIGN_NAME:-Gutter Dev}
LOCAL_ID=$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$LOCAL_SIGN_NAME\"" 'index($0, name) { print $2; exit }' || true)
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Gutter.entitlements \
        --sign "$SIGN_ID" "$APP"
elif [ -n "$LOCAL_ID" ]; then
    codesign --force --entitlements Gutter.entitlements --sign "$LOCAL_ID" "$APP"
    echo "signed with \"$LOCAL_SIGN_NAME\" ($LOCAL_ID)"
else
    codesign --force --entitlements Gutter.entitlements --sign - "$APP"
    echo "ad-hoc signed: privacy grants reset on every rebuild (see BUILDING.html, Signing)"
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

echo "built: $APP ($(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST") build $BUILD, $COMMIT)"

# Replaces /Applications/Gutter.app wholesale. A copy that is running keeps
# going on the old binary, but loads resources lazily, so quit it (cmd-q) and
# relaunch. lsregister points Launch Services at the new copy, so Spotlight and
# `open -a Gutter` find it rather than dist/.
if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Gutter.app
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Gutter.app
    echo "installed: /Applications/Gutter.app"
fi
