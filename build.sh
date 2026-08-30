#!/bin/bash
# Compiles Gutter (vendored Ghostty Swift wrapper + this app) into a
# binary linked against the static libghostty from the GhosttyKit xcframework.
# Run make-app.sh to get a launchable .app (required: the wrapper's logger
# force-unwraps Bundle.main.bundleIdentifier, so the bare binary will crash).
set -euo pipefail
cd "$(dirname "$0")"

# Link inputs: the combined archive OR, if Xcode 26.x libtool dropped its
# unaligned members (zig-emitted members are unaligned), the core archive
# plus every dep archive from the zig cache, passed individually to ld.
GHOSTTY=${GHOSTTY:-$HOME/projects/ak/ghostty}
KIT="$GHOSTTY/macos/GhosttyKit.xcframework/macos-arm64"
LIB="$KIT/libghostty.a"
[ -f "$LIB" ] || LIB="$KIT/libghostty-fat.a"
[ -f "$LIB" ] || {
    echo "error: $KIT/libghostty{,-fat}.a not found - build libghostty first:" >&2
    echo "  cd $GHOSTTY && zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native" >&2
    exit 1
}
[ -d Vendor ] || ./vendor.sh

mkdir -p bin

# Xcode 26.x libtool silently drops and ld64 errors on 64-bit archive members
# whose offsets aren't 8-byte aligned (zig's archive writer doesn't pad).
# Repair: rebuild every zig-cache archive with Apple's ar, which pads members
# correctly; link against the repaired core + deps.
LIBS=""
if nm "$LIB" 2>/dev/null | grep -q ' T _ghostty_init'; then
    LIBS="$LIB"
else
    CORE=$(find "$GHOSTTY/.zig-cache/o" -name 'libghostty.a' -size +8M | head -1)
    [ -f "$CORE" ] || { echo "error: core libghostty.a not found in zig-cache" >&2; exit 1; }
    ZIGAR=${ZIGAR:-$HOME/projects/ak/.tooling/zig-aarch64-macos-0.15.2/zig}
    REPAIRED=bin/repaired
    mkdir -p "$REPAIRED"
    for a in $(find "$GHOSTTY/.zig-cache/o" -name 'lib*.a' ! -name 'libghostty-fat.a'); do
        h=$(basename "$(dirname "$a")")
        [ -f "$REPAIRED/$h.a" ] && continue
        ex="$REPAIRED/x-$h"
        rm -rf "$ex" && mkdir -p "$ex"
        cp "$a" "$ex/lib.a"
        (cd "$ex" && ar x lib.a && chmod -R u+rwX .)
        rm -f "$ex/lib.a"
        objs=$(ls "$ex"/*.o 2>/dev/null | wc -l | tr -d ' ')
        [ "$objs" = "0" ] && { echo "error: no members extracted from $a" >&2; exit 1; }
        ar rcs "$REPAIRED/$h.a" "$ex"/*.o
        echo "repaired $h ($objs members)"


    done
    LIBS=$(find "$REPAIRED" -maxdepth 1 -name '*.a')
    echo "linking against repaired archives (libtool alignment bug workaround)"
fi

# ObjC exception-catching helper (needs ARC + Foundation)
clang -c -fobjc-arc -ObjC \
    -F"$(xcrun --show-sdk-path)/System/Library/Frameworks" \
    Vendor/Support/ObjCExceptionCatcher.m \
    -o bin/ObjCExceptionCatcher.o

# Swift sources: app + vendored wrapper, bridged to libghostty via its
# modulemap. -enable-bare-slash-regex is set upstream in the Xcode project.
# -Xcc -I"Vendor/Support" lets the vendored ObjC header's includes resolve.
swiftc \
    -O \
    -enable-bare-slash-regex \
    -module-name Gutter \
    -import-objc-header Vendor/Support/ObjCExceptionCatcher.h \
    Sources/*.swift \
    Vendor/Ghostty/*.swift \
    "Vendor/Ghostty/Surface View/"*.swift \
    Vendor/Support/*.swift \
    bin/ObjCExceptionCatcher.o \
    -Xcc -fmodule-map-file="$GHOSTTY/include/module.modulemap" \
    -Xcc -I"$GHOSTTY/include" \
    -Xcc -I"Vendor/Support" \
    -L"$KIT" $LIBS \
    -framework AppKit -framework SwiftUI -framework Combine -framework Metal -framework MetalKit \
    -framework CoreVideo -framework QuartzCore -framework IOSurface -framework CoreText \
    -framework CoreGraphics -framework CoreFoundation -framework Carbon -framework UserNotifications \
    -framework UniformTypeIdentifiers \
    -lc++ \
    -o bin/Gutter

echo "built: bin/Gutter (run make-app.sh to get a launchable .app)"
