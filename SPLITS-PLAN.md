# Splits (sub-panes) in Gutter - what shipped

The decisions live in `DESIGN.md` now ("Splits: declined, then reversed" and
"The terminal area is ghostty's, not ours"), per that file's own rule. This file
is only the record of where the plan and the build diverged. It can be deleted.

## Outcome

`⌘D` splits the selected session's terminal area. The sidebar still lists
sessions, one row each; the attention dot still tells the truth when the agent
that wants you is in a pane you are not looking at.

Keybinds are ghostty's own defaults, unchanged - `main.swift` overrides none of
them. Verified in `~/projects/ak/ghostty/src/config/Config.zig:6979-7042`, `:6845`.

## Where the plan was wrong

**1. The renderer.** The plan called for a ~220-line AppKit renderer with
hand-rolled dividers, on the grounds that ghostty's SwiftUI `TerminalSplitTreeView`
"needs `InspectableSurface`, drop zones and an `@EnvironmentObject Ghostty.App`"
and so was unavailable. Three of those four are wrong: `Ghostty.InspectableSurface`
is vendored (`Vendor/Ghostty/Surface View/InspectorView.swift:8`), the environment
object is injectable, and drop zones were out of scope anyway. `SplitView`,
`SplitView.Divider` and `node.structuralIdentity` are vendored too.

What shipped is `Sources/SessionTreeView.swift`, ~60 lines, a near-copy of
upstream minus the drop zones.

**2. `calculateViewBounds` is a trap.** The plan built layout on
`SplitTree.swift:733`. That function has no callers anywhere in ghostty - only
its own recursion - and for vertical splits it disagrees with `spatialSlots`
(`:945`), which is the live convention that `resizing` and spatial `focusTarget`
both use: `calculateViewBounds` gives the top child `1 - ratio`, `spatialSlots`
gives it `ratio`. They agree at 0.5, so a fresh `⇧⌘D` would have looked right and
only keyboard resize would have gone the wrong way. Moot now - `SplitView` is
driven by the ratio directly - but don't reach for that function later.

**3. It removed more than it added.** The plan treated splits as additive. Using
ghostty's own views deleted `FindBarView.swift`, `GutterSurfaceView.swift`, the
container's find-bar plumbing, its cursor rect and its `sizeDidChange` call, and
the hand-repointing of "Change Tab Title...".

## Still out of scope

Drag-and-drop of a pane onto another (`TerminalSplitDropZone`), split layout
persistence across launches, and panes as sidebar rows. Sidebar rows stay
one-per-session.

## Not verified

There is no test suite, and the app could not be driven in this session:
`screencapture` failed ("could not create image from display") and `osascript`
has no assistive access, so nothing below was exercised by a human or a script.
Everything here is a compile-and-launch claim only.

1. `⌘D` / `⇧⌘D` split; the new pane starts in the same cwd.
2. `⌘[` `⌘]` and `⌥⌘arrows` move focus; the focused pane takes keystrokes.
   `⌃⌘arrows` resize; `⌃⌘=` equalizes; `⇧⌘↵` zooms and restores.
3. Divider drag; double-click equalizes. Window resize reflows (`tput cols`).
4. `⌘W` closes a pane, and the session on the last one; `⌥⌘W` closes the session.
5. Click a pane: the sidebar row's title follows the pane you clicked.
6. **Status:** `claude` in a *non-focused* pane of a *non-selected* session -
   the row's dot lights on hand-off, and clears once you look at that pane.
7. **Status:** `sleep 6; echo done` in a background pane rings and lights the dot
   (needs `notify-on-command-finish = unfocused`).
8. **Memory:** four sessions, two panes each, all busy; leave one selected and
   watch `Memory` in Activity Monitor stay flat. The occlusion regression check -
   compare against a pre-splits build before believing it.
9. Right-click a pane: splits and **Terminal Inspector** are both live now, and
   the inspector has never run in Gutter before - most likely thing to be broken.
10. `⌘?`, README and `CONFIG.md` list the same keys the menu shows.
