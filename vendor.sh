#!/bin/bash
# Copies the Ghostty Swift wrapper (macos/Sources/Ghostty) plus the app-target
# support files it references from a ghostty checkout into Vendor/.
# Source must be the same version as the libghostty.a being linked (v1.3.1).
set -euo pipefail

GHOSTTY=${1:-${GHOSTTY:-$HOME/projects/ak/ghostty}}
SRC="$GHOSTTY/macos/Sources"
DEST="$(cd "$(dirname "$0")" && pwd)/Vendor"

[ -d "$SRC/Ghostty" ] || { echo "ghostty sources not found at $SRC" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/Ghostty" "$DEST/Support"

# Core wrapper. SurfaceView_UIKit.swift is excluded: upstream separates it by
# Xcode target membership, not #if os() gates.
rsync -a --exclude 'SurfaceView_UIKit.swift' "$SRC/Ghostty/" "$DEST/Ghostty/"

# App-target files the wrapper references (all verified against v1.3.1):
cp "$SRC/Helpers/CrossKit.swift"                       "$DEST/Support/"  # OSView/OSColor typealiases
cp "$SRC/Helpers/KeyboardLayout.swift"                 "$DEST/Support/"  # keyDown layout fallback
cp "$SRC/Helpers/Fullscreen.swift"                     "$DEST/Support/"  # FullscreenMode enum
cp "$SRC/Helpers/Extensions/UserDefaults+Extension.swift" "$DEST/Support/"
cp "$SRC/Helpers/Extensions/NSPasteboard+Extension.swift" "$DEST/Support/"
cp "$SRC/Helpers/Extensions/EventModifiers+Extension.swift" "$DEST/Support/"  # SwiftUI EventModifiers(nsFlags:)
cp "$SRC/Helpers/Extensions/Transferable+Extension.swift"  "$DEST/Support/"  # pasteboardItem() used by SurfaceDragSource
cp "$SRC/Helpers/Cursor.swift"                             "$DEST/Support/"  # CursorStyle used by SurfaceView pointer style
# HiddenTitlebarTerminalWindow is NOT vendored: SurfaceScrollView only casts to it
# for a macOS 26.0-only bug workaround; a shim subclass covers the reference.
cp "$SRC/Helpers/Extensions/NSScreen+Extension.swift"      "$DEST/Support/"  # displayID
cp "$SRC/Helpers/Extensions/NSMenuItem+Extension.swift"    "$DEST/Support/"  # setImageIfDesired
cp "$SRC/Helpers/Extensions/NSAppearance+Extension.swift"  "$DEST/Support/"  # NSAppearance(ghosttyConfig:)
# TerminalRestorable.swift is NOT vendored (pulls TerminalController etc.);
# only its error enum is used by SurfaceView's Codable init - shimmed in Shims.swift.
cp "$SRC/Helpers/Weak.swift"                               "$DEST/Support/"  # Weak box used by SurfaceView env keys
cp "$SRC/Features/Secure Input/SecureInputOverlay.swift"   "$DEST/Support/"  # SwiftUI overlay used by SurfaceView.swift
cp "$SRC/Helpers/Backport.swift"                           "$DEST/Support/"  # SwiftUI backport helpers (.backport.link)
cp "$SRC/Helpers/Extensions/Optional+Extension.swift"      "$DEST/Support/"  # Optional<String>.withCString
cp "$SRC/Helpers/Extensions/Array+Extension.swift"         "$DEST/Support/"  # Array<String>.withCStrings
cp "$SRC/Helpers/Extensions/NSWindow+Extension.swift"      "$DEST/Support/"  # addTabbedWindowSafely used by Fullscreen
cp "$SRC/Helpers/Extensions/NSApplication+Extension.swift" "$DEST/Support/"  # presentation options used by Fullscreen
cp "$SRC/Helpers/Private/CGS.swift"                        "$DEST/Support/"  # CGSSpace private API used by Fullscreen
cp "$SRC/Helpers/Private/Dock.swift"                       "$DEST/Support/"  # Dock orientation used by QuickTerminalPosition
cp "$SRC/Helpers/Extensions/NSView+Extension.swift"        "$DEST/Support/"  # rootView/firstDescendant/descendants

# ObjC exception-catching helper (GhosttyAddTabbedWindowSafely) referenced by
# NSWindow+Extension; the .h/.m are compiled and linked by build.sh.
cp "$SRC/Helpers/ObjCExceptionCatcher.h" "$DEST/Support/"
cp "$SRC/Helpers/ObjCExceptionCatcher.m" "$DEST/Support/"
cp "$SRC/Features/Secure Input/SecureInput.swift"      "$DEST/Support/"
cp "$SRC/Features/Splits/SplitTree.swift"              "$DEST/Support/"  # referenced by Ghostty.App split actions
cp "$SRC/Features/Splits/SplitView.swift"              "$DEST/Support/"  # referenced by InspectorView
cp "$SRC/Features/Splits/SplitView.Divider.swift"      "$DEST/Support/"

# Config color/quick-terminal helpers referenced by Ghostty.Config
cp "$SRC/Helpers/Extensions/OSColor+Extension.swift"   "$DEST/Support/"  # OSColor(ghostty:), darken, isLightColor
cp "$SRC/Helpers/AppInfo.swift"                        "$DEST/Support/"  # isRunningInXcode
cp "$SRC/Features/QuickTerminal/QuickTerminalPosition.swift"       "$DEST/Support/"
cp "$SRC/Features/QuickTerminal/QuickTerminalScreen.swift"         "$DEST/Support/"
cp "$SRC/Features/QuickTerminal/QuickTerminalSize.swift"           "$DEST/Support/"
cp "$SRC/Features/QuickTerminal/QuickTerminalSpaceBehavior.swift"  "$DEST/Support/"

# Ghostty.Error.swift has no imports (upstream relies on Xcode's cross-file
# import leaking in batch mode); give it what it needs explicitly.
{ echo "import Foundation"; cat "$SRC/Ghostty/Ghostty.Error.swift"; } > "$DEST/Ghostty/Ghostty.Error.swift"

# Swift 6.3.3 (CLT) type-checker blows up on the tuple-destructuring ForEach
# in the key-sequence indicator; use an indices-based ForEach instead.
# Single occurrence, verified against the v1.3.1 source.
python3 - "$DEST/Ghostty/Surface View/SurfaceView.swift" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "ForEach(Array(keySequence.enumerated()), id: \\.offset) { _, key in"
new = "ForEach(keySequence.indices, id: \\.self) { idx in"
assert s.count(old) == 1, f"expected 1 occurrence, got {s.count(old)}"
s = s.replace(old, new)
assert s.count("KeyCap(key.description)") == 1
s = s.replace("KeyCap(key.description)", "KeyCap(keySequence[idx].description)")
old2 = "ForEach(Array(keyTables.enumerated()), id: \\.offset) { index, table in"
new2 = "ForEach(keyTables.indices, id: \\.self) { index in"
assert s.count(old2) == 1, f"expected 1 occurrence, got {s.count(old2)}"
s = s.replace(old2, new2)
assert s.count("Text(verbatim: table)") == 1
s = s.replace("Text(verbatim: table)", "Text(verbatim: keyTables[index])")
p.write_text(s)
print("patched SurfaceView.swift ForEach")
PYEOF

# Ghostty.App.swift: goto_tab performability. Upstream requires a native
# tabGroup with >1 windows; this embedder keeps sessions in its own sidebar,
# so perform when the embedder (NSApp.delegate) has >1 sessions instead.
# Only the gotoTab occurrence is patched (moveTab needs real windows).
# Verified against the v1.3.1 source.
python3 - "$DEST/Ghostty/Ghostty.App.swift" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """                    // Similar to goto_split (see comment there) about our performability,
                    // we should make this more accurate later.
                    guard (surfaceView.window?.tabGroup?.windows.count ?? 0) > 1 else { return false }"""
new = """                    // Gutter patch: no native tabGroup; performable when the
                    // embedder (NSApp.delegate) has more than one session.
                    guard (NSApp.delegate as? AppDelegate)?.sessions.sessions.count ?? 0 > 1 else { return false }"""
assert s.count(old) == 1, f"expected 1 occurrence, got {s.count(old)}"
p.write_text(s.replace(old, new))
print("patched Ghostty.App.swift goto_tab guard")
PYEOF

# Ghostty.Config.swift: let the embedder append an extra config file (used
# for keybind overrides like cmd+t=new_tab) after user config, before finalize.
python3 - "$DEST/Ghostty/Ghostty.Config.swift" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
anchor = "    convenience init(at path: String? = nil, finalize: Bool = true) {"
addition = """    /// Gutter: optional extra config file loaded after the user's config
    /// (used for embedder keybind overrides). Set before creating Ghostty.App.
    static var embedderConfigFile: String?

"""
assert s.count(anchor) == 1
s = s.replace(anchor, addition + anchor)
old = "            ghostty_config_load_recursive_files(cfg)\n#endif"
new = """            ghostty_config_load_recursive_files(cfg)

            // Gutter: append the embedder's extra config file.
            if let extra = Self.embedderConfigFile {
                ghostty_config_load_file(cfg, extra)
            }
#endif"""
assert s.count(old) == 1, f"expected 1 occurrence, got {s.count(old)}"
p.write_text(s.replace(old, new))
print("patched Ghostty.Config.swift embedder hook")
PYEOF

# SurfaceView_AppKit.swift: drop the 👻 fallback title upstream schedules when
# a surface has no title yet - the sidebar leaves it blank until the shell
# sets one.
python3 - "$DEST/Ghostty/Surface View/SurfaceView_AppKit.swift" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """            // Set a timer to show the ghost emoji after 500ms if no title is set
            titleFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                if let self = self, self.title.isEmpty {
                    self.title = "👻"
                }
            }
"""
new = """            // Gutter patch: upstream shows a 👻 fallback title 500ms after
            // surface creation if the shell hasn't set one yet; the sidebar
            // leaves it blank until the shell sets a title, so no timer needed.
"""
assert s.count(old) == 1, f"expected 1 occurrence, got {s.count(old)}"
p.write_text(s.replace(old, new))
print("patched SurfaceView_AppKit.swift ghost title fallback")
PYEOF

echo "vendored $(find "$DEST" -name '*.swift' | wc -l | tr -d ' ') swift files from $GHOSTTY"
