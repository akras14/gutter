#!/bin/bash
# Rebuilds deps/ and Vendor/ from the ghostty release named in
# deps/GHOSTTY_VERSION. Only needed to move to a new ghostty: building Gutter
# uses the committed deps/ and needs none of this.
#
#   1. edit deps/GHOSTTY_VERSION (tag and the commit it points at)
#   2. ./update-ghostty.sh
#   3. ./build.sh, check the app, commit deps/ and Vendor/
#
# The checkout and the Zig toolchain live outside the repo, in
# $GUTTER_GHOSTTY_CACHE (default ~/.cache/gutter-ghostty): the zig cache alone
# is a couple of GB.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$PWD

CACHE=${GUTTER_GHOSTTY_CACHE:-$HOME/.cache/gutter-ghostty}
read -r TAG COMMIT < deps/GHOSTTY_VERSION
SRC="$CACHE/ghostty"
mkdir -p "$CACHE"

# --- source ---------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$TAG" https://github.com/ghostty-org/ghostty.git "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin tag "$TAG"
    git -C "$SRC" checkout --force "$TAG"
fi
HEAD=$(git -C "$SRC" rev-parse HEAD)
case "$HEAD" in
    "$COMMIT"*) ;;
    *) echo "error: $TAG is $HEAD, deps/GHOSTTY_VERSION says $COMMIT" >&2; exit 1 ;;
esac

# --- zig ------------------------------------------------------------------
# The exact version ghostty asks for, checked against ziglang.org's index.
ZIGVER=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' "$SRC/build.zig.zon")
ZIGDIR="$CACHE/zig-aarch64-macos-$ZIGVER"
if [ ! -x "$ZIGDIR/zig" ]; then
    INFO=$(curl -fsSL https://ziglang.org/download/index.json | python3 -I -c "
import json, sys
d = json.load(sys.stdin)['$ZIGVER']['aarch64-macos']
print(d['tarball'], d['shasum'])")
    read -r URL SHA <<< "$INFO"
    curl -fsSL "$URL" -o "$CACHE/zig.tar.xz"
    echo "$SHA  $CACHE/zig.tar.xz" | shasum -a 256 -c
    tar xf "$CACHE/zig.tar.xz" -C "$CACHE"
    rm "$CACHE/zig.tar.xz"
fi

# --- shaders --------------------------------------------------------------
# The renderer embeds a precompiled metallib, and `metal` ships only with full
# Xcode. Without it, reuse the metallib embedded in the libghostty.a being
# replaced - allowed only when the shader source is the one it was compiled
# from (deps/SHADERS_SHA256), so a stale shader can't slip in.
SHADER_SHA=$(shasum -a 256 "$SRC/src/renderer/shaders/shaders.metal" | cut -d' ' -f1)
git -C "$SRC" checkout -- src/build/MetallibStep.zig
if ! /usr/bin/xcrun -sdk macosx -f metal >/dev/null 2>&1; then
    if [ "$SHADER_SHA" != "$(cat deps/SHADERS_SHA256)" ]; then
        echo "error: shaders.metal changed in $TAG and \`metal\` is unavailable." >&2
        echo "  Install Xcode (xcode-select -s /Applications/Xcode.app) and rerun." >&2
        exit 1
    fi
    python3 -I - deps/lib/libghostty.a "$CACHE/Ghostty.metallib" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
# A metallib starts "MTLB"; its total length is the u64 at offset 16.
i = d.find(b'MTLB\x01\x80')
assert i >= 0, "no metallib in the old libghostty.a"
n = int.from_bytes(d[i+16:i+24], 'little')
open(sys.argv[2], 'wb').write(d[i:i+n])
print(f"reusing embedded metallib ({n} bytes)")
PYEOF
    python3 -I - "$SRC/src/build/MetallibStep.zig" "$CACHE/Ghostty.metallib" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
anchor = '    const self = b.allocator.create(MetallibStep) catch @panic("OOM");\n'
assert s.count(anchor) == 1, f"expected 1 occurrence, got {s.count(anchor)}"
add = f'''    const prebuilt = b.addWriteFiles();
    self.* = .{{
        .step = &prebuilt.step,
        .output = prebuilt.addCopyFile(.{{ .cwd_relative = "{sys.argv[2]}" }}, "Ghostty.metallib"),
    }};
    if (true) return self;
'''
p.write_text(s.replace(anchor, anchor + add))
PYEOF
fi

# --- build ----------------------------------------------------------------
# The last step wraps the library in an xcframework, which needs Xcode's
# xcodebuild. Without Xcode a PATH shim stands in for that one call and copies
# the library to where the xcframework would have it.
SHIM="$CACHE/shim-bin"
rm -rf "$SHIM"
if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    mkdir -p "$SHIM"
    cat > "$SHIM/xcodebuild" <<'SHEOF'
#!/bin/bash
[ "${1:-}" = "-create-xcframework" ] || exec /usr/bin/xcodebuild "$@"
# Lay the library out where the real xcframework would put it.
while [ $# -gt 0 ]; do
    case "$1" in
        -library) lib=$2; shift ;;
        -output) out=$2; shift ;;
    esac
    shift
done
rm -rf "$out" && mkdir -p "$out/macos-arm64" && cp "$lib" "$out/macos-arm64/"
SHEOF
    chmod +x "$SHIM/xcodebuild"
fi
(cd "$SRC" && PATH="$SHIM:$PATH" "$ZIGDIR/zig" build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native)

# --- deps/ ----------------------------------------------------------------
rm -rf deps/include deps/share
cp -R "$SRC/include" deps/include
mkdir -p deps/share
cp -R "$SRC/zig-out/share/ghostty" "$SRC/zig-out/share/terminfo" deps/share/

# The xcframework's archive is upstream's own combination of every static
# dependency, with compiler_rt's libc/libm symbols localized so memcpy and
# friends bind to libSystem (src/build/libsystem_override.sh). Dropping its
# debug info takes it from ~150 MB to ~25 MB.
LIB=$(ls "$SRC"/macos/GhosttyKit.xcframework/macos-arm64*/libghostty*.a | head -1)
OUT="$CACHE/libghostty.a"
cp "$LIB" "$OUT"
chmod u+w "$OUT"
strip -S "$OUT"
ranlib "$OUT"
nm "$OUT" 2>/dev/null | grep ' T _ghostty_init$' >/dev/null || { echo "error: libghostty.a has no ghostty_init" >&2; exit 1; }
mkdir -p deps/lib && mv "$OUT" deps/lib/libghostty.a
echo "$SHADER_SHA" > deps/SHADERS_SHA256

# --- Vendor/ --------------------------------------------------------------
"$REPO/vendor.sh" "$SRC"

echo "updated deps/ and Vendor/ to ghostty $TAG ($(du -h deps/lib/libghostty.a | cut -f1) libghostty.a)"
