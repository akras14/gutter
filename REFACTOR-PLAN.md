# Gutter refactor plan

**Purpose:** a self-contained work order. Anyone (or any agent) picking this up in a
fresh session should be able to execute it top to bottom without re-deriving context.

**How to use it:** do ONE step per sitting, in order. After each step, run the build,
then tick that step's boxes in this file and commit the file along with the change (if
the user asks for commits). If a step fails in a way this document did not predict,
STOP and report — do not improvise a different design.

---

## 0. Context you need before touching anything

Gutter is a small native macOS terminal app: one window, a collapsible sidebar of
sessions on the left, one live terminal surface on the right. It embeds **libghostty
v1.3.1** as a static library and reuses ghostty's own Swift wrapper.

| Path | What it is | May I edit it? |
|---|---|---|
| `Sources/*.swift` | The app. ~900 lines total. | **Yes — this is the only code this plan touches.** |
| `Vendor/**` | Ghostty's Swift wrapper, copied verbatim from an upstream checkout by `vendor.sh`. | **No.** Edits get wiped by the next `./vendor.sh`. |
| `deps/**` | Committed prebuilt `libghostty.a`, headers, themes, terminfo. | **No.** |
| `build.sh` / `make-app.sh` / `vendor.sh` | Build scripts. No Xcode project exists. | Only if a step says so. |

Key facts that will otherwise confuse you:

- **There is no Xcode project and no test suite.** Verification = "it compiles" plus
  a human clicking around. You cannot assert correctness by running tests.
- **`build.sh` globs `Sources/*.swift`.** Adding, renaming, or deleting a file in
  `Sources/` needs no build-script change.
- **The bare `bin/Gutter` binary crashes on launch** (ghostty's logger force-unwraps
  `Bundle.main.bundleIdentifier`). Always test through `dist/Gutter.app`.
- **`Ghostty.SurfaceView` is the real terminal.** A `Session` is just a wrapper around
  one `SurfaceView` plus sidebar display state (title, activity dot).
- Two overlapping keybind paths exist for the same keys, and this trips people up:
  the **menu** (`Sources/MainMenu.swift` → `AppDelegate` actions) and **ghostty's own
  core keybinds** (config → libghostty → `NSNotification` → `GhosttyBridge`). `cmd-t`
  works through both. That is why a broken bridge can look like a working app.

### Current architecture (after this plan, unchanged in shape — just cleaner)

```
main.swift            process setup: GHOSTTY_RESOURCES_DIR, ghostty_init, keybind overrides
  └─ AppDelegate      app lifecycle + menu actions
       ├─ Ghostty.App          libghostty runtime + config (from Vendor/)
       ├─ GhosttyBridge        the ONLY place that knows ghostty notification names
       ├─ SessionManager       the list of sessions + which is selected (the model)
       └─ MainWindowController the window, toolbar, fullscreen chrome
            └─ MainSplitViewController
                 ├─ SidebarViewController        NSTableView, one row per session
                 └─ TerminalContainerViewController  hosts the selected SurfaceView
```

The goal of this plan is **not** to change that shape. It is to fix one real bug and
push each piece of logic into the box it already belongs in.

---

## 1. House rules

- **Do not edit `Vendor/` or `deps/`.** If a change seems to require it, stop and ask.
- **Do not commit unless the user asks.** The repo is on `master`; if the user does
  ask, create a branch first.
- **Do not add dependencies, a package manager, an Xcode project, or a test harness.**
- **Do not "improve" things this plan does not list.** Scope creep here is expensive
  because nothing is testable automatically.
- **Preserve the comments.** The existing comments record hard-won bug fixes (fullscreen
  bar behavior, first-keystroke focus, `command` config quirks). Move them with the code
  they explain; do not delete them as "noise".
- **You cannot verify GUI behavior yourself.** After building, ask the user to run the
  manual check listed in the step.

---

## 2. Build & verify

```sh
./build.sh                 # compile only, ~30s. Success = last line "built: bin/Gutter"
./make-app.sh              # assemble dist/Gutter.app (also runs build.sh if needed)
open dist/Gutter.app       # launch for manual checks
```

**The build prints a wall of warnings on success.** This is normal and pre-existing —
`Sendable` conformance warnings from the vendored wrapper, a `@retroactive`
conformance warning from `Sources/Compat.swift:27`, and a dozen
`ld: warning: object file ... was built for newer 'macOS' version` lines from
`deps/lib/libghostty.a`. **Do not try to fix these.** Only judge success by the final
line: `built: bin/Gutter`. If compilation fails, `swiftc` errors appear and that line
is absent.

Baseline confirmed: the tree builds clean as of the start of this plan.

---

## 3. Starting state

Working tree has two **uncommitted** files: `Sources/AppDelegate.swift` and
`Sources/MainWindowController.swift` (a launch-focus fix — the first keystroke after
launch was being dropped). Step 9 folds that work in properly.

- [x] Confirm `./build.sh` succeeds before making any change
- [x] Ask the user whether to commit the uncommitted focus fix first (keeps the
      refactor diff readable) or leave it in the working tree
      — committed as `4ca0a9c` on `master`

---

## Step 1 — Retain `GhosttyBridge` (real bug, fix first)

**Why:** `Sources/AppDelegate.swift:43` reads `_ = GhosttyBridge(sessions: sessions,
ghostty: ghostty)`. Nothing stores the returned object, so ARC deallocates it at the
end of that line. Every observer inside `GhosttyBridge` captures `[weak self]`, so all
of them silently become no-ops the instant the app launches: `requestClose`,
`ghosttyCloseSurface`, `ghosttyNewTab`, `ghosttyCloseTab`, `ghosttyGotoTab`. (The
fullscreen observer survives — it does not capture `self`.)

Today that means **closing a tab does nothing** and sessions are never removed when a
surface dies. `cmd-t` still appears to work because the *menu* item reaches
`AppDelegate.newTab` directly, which masks the failure.

**Edit — `Sources/AppDelegate.swift`:**

Add a stored property next to the existing `windowController` property (~line 28):

```swift
private var windowController: MainWindowController!
private var bridge: GhosttyBridge!        // <-- add: must be retained or its observers die
let sessions = SessionManager()
```

Change line 43 from:

```swift
_ = GhosttyBridge(sessions: sessions, ghostty: ghostty)
```

to:

```swift
bridge = GhosttyBridge(sessions: sessions, ghostty: ghostty)
```

- [x] Property added
- [x] Assignment changed
- [x] `./build.sh` succeeds
- [x] Manual check: open 2 tabs, press `cmd-w` — the tab closes and the sidebar row
      disappears. Close the last tab — the app quits.

---

## Step 2 — Give `SessionManager` the `Ghostty.App`

**Why:** `newSession(app:)` makes every caller unwrap `ghostty.app` first (three
places), and the `requestClose` closure exists only because `SessionManager` has no way
to talk to ghostty itself. Handing it the app once removes both.

**Edit — `Sources/SessionManager.swift`:**

Add a stored property and an initializer to `SessionManager`, and delete `requestClose`:

```swift
final class SessionManager {
    private let ghostty: Ghostty.App          // <-- add

    init(ghostty: Ghostty.App) {              // <-- add
        self.ghostty = ghostty
    }

    private(set) var sessions: [Session] = []
    private(set) var selected: Session?

    // DELETE this property and its doc comment:
    // var requestClose: ((Ghostty.SurfaceView) -> Void)?
```

Change `newSession` to take no argument and unwrap the app itself:

```swift
@discardableResult
func newSession() -> Session? {
    guard let app = ghostty.app else { return nil }
    let view = Ghostty.SurfaceView(app, baseConfig: nil, uuid: nil)
    ...                                        // rest of the body is unchanged
}
```

Change `close(_:)` to call ghostty directly:

```swift
func close(_ session: Session) {
    if let surface = session.view.surface {
        ghostty.requestClose(surface: surface)
    } else {
        remove(session)
    }
}
```

**Edit — `Sources/GhosttyBridge.swift`:**

Delete the whole `sessions.requestClose = { ... }` assignment from `init` (~lines
16–19). In the `ghosttyNewTab` observer, drop the app unwrap:

```swift
nc.addObserver(forName: Ghostty.Notification.ghosttyNewTab, object: nil, queue: .main) {
    [weak self] _ in
    self?.sessions.newSession()
}
```

**Edit — `Sources/AppDelegate.swift`:**

`SessionManager` now needs `ghostty` at construction time, and a stored-property
initializer cannot reference another stored property. So it must move into
`applicationDidFinishLaunching`:

```swift
private var sessions: SessionManager!          // was: let sessions = SessionManager()
```

and inside `applicationDidFinishLaunching`, immediately after the readiness `guard`
(the `guard ghostty.readiness == .ready, let app = ghostty.app else { ... }` block):

```swift
sessions = SessionManager(ghostty: ghostty)
```

Then update the remaining call sites:

- `sessions.newSession(app: app)` → `sessions.newSession()` (both in
  `applicationDidFinishLaunching` and in `@objc func newTab`)
- `@objc func newTab` no longer needs `guard let app = ghostty.app else { return }` —
  delete that line, keep the `Self.logger.info(...)` line
- `findSurface(forUUID:)` becomes `sessions?.surface(for: uuid)` — an implicitly
  unwrapped optional supports `?.`, and this guards against libghostty calling in
  before launch finishes

**Watch out:** the `guard ... let app = ghostty.app` in `applicationDidFinishLaunching`
may now be unused. If the compiler warns, change it to `guard ghostty.readiness ==
.ready, ghostty.app != nil else { ... }`. Keep the guard itself — it shows the config
error alert.

- [x] `SessionManager` takes and stores `Ghostty.App`; `requestClose` deleted
- [x] `newSession()` takes no argument
- [x] `close(_:)` calls `ghostty.requestClose(surface:)`
- [x] `GhosttyBridge` no longer sets `requestClose`
- [x] `AppDelegate` constructs `SessionManager` in `applicationDidFinishLaunching`
- [x] `./build.sh` succeeds
- [x] Manual check: `cmd-t` opens a tab, `cmd-w` closes it (both still work)

> Deviation from plan: `sessions` had to stay `private(set) var`, not `private var` —
> a "Gutter patch" in `Vendor/Ghostty/Ghostty.App.swift:1139` reads
> `(NSApp.delegate as? AppDelegate)?.sessions.sessions.count`.
>
> Follow-up (applied after validation): that made `sessions` an implicitly unwrapped
> optional, so the vendored line above force-unwraps it — nil until
> `applicationDidFinishLaunching` runs. Changed to
> `private(set) lazy var sessions = SessionManager(ghostty: ghostty)`, which is
> non-optional again and still able to read `ghostty`. The explicit assignment in
> `applicationDidFinishLaunching` is gone (the `GhosttyBridge` line now triggers
> the lazy init at the same moment), and `findSurface` is back to `sessions.surface(for:)`.

---

## Step 3 — Toggle the sidebar through the responder chain

**Why:** the toggle currently travels menu → `AppDelegate.toggleSidebar` →
`windowController` → `splitVC`, and `Sources/MainWindowController.swift:83` hardcodes
`#selector(AppDelegate.toggleSidebar(_:))` — a window that depends on the app delegate,
which is backwards. `NSSplitViewController.toggleSidebar(_:)` already exists as a
responder-chain action, and `MainSplitViewController` is the window's content view
controller, so it is already in the chain. A **nil-target** item finds it by itself.

**This step must come before Step 4**, because it removes the last outside user of
`splitVC`, which Step 4 makes private.

**Edit — `Sources/MainMenu.swift`** (~line 30):

```swift
let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar",
                               action: #selector(NSSplitViewController.toggleSidebar(_:)),
                               keyEquivalent: "s")
sidebar.keyEquivalentModifierMask = [.command, .control]
// No explicit target: the responder chain delivers this to MainSplitViewController.
```

(Delete the `sidebar.target = target` line. Leave every other item's `target = target`
alone — those still point at `AppDelegate`.)

**Edit — `Sources/MainWindowController.swift`** (~line 82, in
`toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`):

```swift
// Nil target: the responder chain delivers this to MainSplitViewController.
item.action = #selector(NSSplitViewController.toggleSidebar(_:))
```

**Edit — `Sources/AppDelegate.swift`:** delete the whole `@objc func toggleSidebar`
method (~lines 112–114).

**Watch out:** if the menu item or toolbar button renders **greyed out**, the responder
chain is not reaching the split view controller. Do not fight it — revert this one step
and report; the forwarding version works.

- [x] `MainMenu` sidebar item uses the `NSSplitViewController` selector, no target
- [x] Toolbar item uses the same selector, no `AppDelegate` reference
- [x] `AppDelegate.toggleSidebar` deleted
- [x] `./build.sh` succeeds
- [x] Manual check: `ctrl-cmd-S` toggles the sidebar; the toolbar button toggles it;
      neither appears greyed out

---

## Step 4 — Move session→UI wiring into `MainWindowController`

**Why:** `AppDelegate` currently reaches two levels down into the view tree
(`windowController.splitVC.sidebarReload()`). Updating the sidebar and focusing the
surface are window concerns, and `MainWindowController` already receives `sessions` in
its initializer — it should subscribe itself.

**Edit — `Sources/AppDelegate.swift`:** delete both closure assignments from
`applicationDidFinishLaunching` (~lines 50–57):

```swift
// DELETE:
sessions.onListChanged = { [weak windowController] in
    windowController?.splitVC.sidebarReload()
}
sessions.onSelectionChanged = { [weak windowController] session in
    guard let split = windowController?.splitVC else { return }
    split.show(session)
    split.view.window?.makeFirstResponder(session?.view)
}
```

**Edit — `Sources/MainWindowController.swift`:** add the same wiring at the end of
`init(sessions:)` (after the existing split/frame setup):

```swift
sessions.onListChanged = { [weak self] in
    self?.splitVC.sidebarReload()
}
sessions.onSelectionChanged = { [weak self] session in
    guard let self else { return }
    self.splitVC.show(session)
    self.window?.makeFirstResponder(session?.view)
}
```

Then tighten the property. It is currently an implicitly unwrapped `var` only because
it was assigned after `super.init`; Swift lets you assign a `let` *before* `super.init`:

```swift
private let splitVC: MainSplitViewController      // was: var splitVC: MainSplitViewController!

init(sessions: SessionManager) {
    let split = MainSplitViewController(sessions: sessions)
    self.splitVC = split                          // <-- move here, before super.init
    self.sessions = sessions

    let window = NSWindow(...)
    window.title = "Gutter"

    super.init(window: window)
    // delete the old `self.splitVC = split` that sat here
    ...
}
```

**Watch out:** every stored property must be initialized before `super.init` is called.
If the compiler complains about `self` being used before initialization, you moved the
assignment to the wrong side of `super.init(window:)`.

- [x] Closures deleted from `AppDelegate`
- [x] Closures added at the end of `MainWindowController.init`
- [x] `splitVC` is a `private let`, assigned before `super.init`
- [x] `./build.sh` succeeds
- [x] Manual check: opening/closing tabs updates the sidebar; clicking a sidebar row
      switches the visible terminal and typing goes to it immediately

---

## Step 5 — Get app-lifecycle policy out of `SessionManager`

**Why:** `Sources/SessionManager.swift:120` calls `NSApp.terminate(nil)`. A model class
should not decide the app quits. `applicationShouldTerminateAfterLastWindowClosed`
already returns `true`, so closing the window achieves the same thing.

**Edit — `Sources/SessionManager.swift`:** add a callback next to the other two:

```swift
var onListChanged: (() -> Void)?
var onSelectionChanged: ((Session?) -> Void)?
var onEmpty: (() -> Void)?          // <-- add
```

and at the end of `remove(_:)`:

```swift
if sessions.isEmpty {
    onEmpty?()                       // was: NSApp.terminate(nil)
}
```

**Edit — `Sources/MainWindowController.swift`:** with the other subscriptions from
Step 4:

```swift
sessions.onEmpty = { [weak self] in
    self?.window?.close()
}
```

**Watch out:** use `close()`, not `performClose(nil)` — `performClose` consults the
window delegate and can be vetoed.

- [x] `onEmpty` added and fired; `NSApp.terminate` removed from `SessionManager`
- [x] `MainWindowController` closes the window on empty
- [x] `./build.sh` succeeds
- [x] Manual check: closing the last tab quits the app (this is intentional, it matches
      Terminal.app)

---

## Step 6 — Dedupe the session lookup

**Why:** `Sources/GhosttyBridge.swift:25` and `:39` both spell out
`sessions.first(where: { $0.view === view })`.

**Edit — `Sources/SessionManager.swift`:** add next to the existing `surface(for:)`:

```swift
func session(for view: Ghostty.SurfaceView) -> Session? {
    sessions.first { $0.view === view }
}
```

**Edit — `Sources/GhosttyBridge.swift`:** both observers become:

```swift
guard let self, let view = note.object as? Ghostty.SurfaceView,
      let session = self.sessions.session(for: view) else { return }
```

Note the two observers call **different** methods afterwards and that difference is
deliberate: `ghosttyCloseSurface` calls `sessions.remove(session)` (the surface is
already gone), `ghosttyCloseTab` calls `sessions.close(session)` (ask ghostty to close
it first). Do not unify them.

- [x] `session(for:)` added
- [x] Both call sites use it
- [x] `./build.sh` succeeds

---

## Step 7 — Rename `TerminalShell.swift`

**Why:** the file contains `MainSplitViewController` and
`TerminalContainerViewController`; nothing in it is called `TerminalShell`.

```sh
git mv Sources/TerminalShell.swift Sources/MainSplitViewController.swift
```

Optionally also split `TerminalContainerViewController` into its own file. `build.sh`
globs `Sources/*.swift`, so no script change is needed.

- [x] File renamed (`TerminalContainerViewController` left in the same file)
- [x] `README.md` layout table updated (it names `TerminalShell.swift`)
- [x] `./build.sh` succeeds

---

## Step 8 — Simplify launch focus (OPTIONAL — do last, revert if unsure)

**Why:** the uncommitted diff put first-keystroke focus logic in two places:
`windowDidBecomeKey` in `MainWindowController`, and a trailing block in
`applicationDidFinishLaunching`. The trailing block is only needed because
`windowDidBecomeKey` fires during `showWindow(nil)`, when `sessions.selected` is still
`nil` — the first session is created *after* the window is shown. Creating the session
first makes `windowDidBecomeKey` sufficient on its own.

**Edit — `Sources/AppDelegate.swift`,** in `applicationDidFinishLaunching`, reorder to:

```swift
sessions.newSession()                 // moved up, before the window is shown
windowController.showWindow(nil)
NSApp.activate(ignoringOtherApps: true)
```

and delete the trailing block:

```swift
// DELETE:
if let window = windowController.window, !window.isKeyWindow {
    window.makeKeyAndOrderFront(nil)
}
if let session = sessions.selected {
    windowController.window?.makeFirstResponder(session.view)
}
```

**Watch out:** this is the most fragile step and it touches a bug the user already
fought twice (see commits `3999c3a`, `f8d6019`). It is cosmetic — it removes duplicated
logic, nothing more. If the manual check below fails at all, **revert this step and
keep the duplication.** A working app beats a tidy one.

- [x] Reordered and trailing block deleted
- [x] `./build.sh && ./make-app.sh` succeeds
- [x] Manual check: launch the app fresh and type immediately without clicking — every
      character must appear in the terminal. Also `cmd-t` immediately after launch.

---

## Step 9 — Final verification

- [x] `./build.sh && ./make-app.sh` succeeds from a clean `bin/`
- [x] `open dist/Gutter.app` and walk the full surface:
  - [x] `cmd-t` (menu) opens a tab; ghostty's own `cmd-t` keybind also opens one
  - [x] `cmd-w` closes a tab and the sidebar row goes away
  - [x] `cmd-1` … `cmd-9` select tabs
  - [x] `ctrl-tab` / `ctrl-shift-tab` cycle
  - [x] `ctrl-cmd-S` and the toolbar button toggle the sidebar
  - [x] Fullscreen: the top bar disappears and returns only when the pointer hits the
        top strip of the screen
  - [x] Tab titles update from the shell; the activity dot appears on a background tab
        that rings the bell
  - [x] Closing the last tab quits the app
- [x] `README.md` layout table matches the files that now exist
- [x] Committed step by step on `master` (user opted out of a branch)

### Expected result

`AppDelegate` shrinks to app lifecycle plus menu actions. `MainWindowController` owns
everything window- and display-related. `GhosttyBridge` is the single libghostty
boundary and is actually alive. `SessionManager` is a pure model with no AppKit
lifecycle policy. Roughly 40 fewer lines, no intended behavior change — except the
things Step 1 fixes, which were broken.
