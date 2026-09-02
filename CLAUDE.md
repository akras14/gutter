# Gutter

A native macOS terminal app: one window, a sidebar of sessions, one live terminal
surface. It embeds libghostty v1.3.1 as a static library and reuses ghostty's own Swift
wrapper. `README.md` has the architecture diagram and the full build notes.

## Build and run

```sh
./build.sh      # compile, ~30s
./make-app.sh   # assemble dist/Gutter.app
open dist/Gutter.app
```

`build.sh` globs `Sources/*.swift`, so adding, renaming, or deleting a file there needs
no build-script change.

## Constraints

- **Edit `Sources/` only.** `Vendor/` is ghostty's Swift wrapper, copied verbatim by
  `vendor.sh`, and `deps/` holds the prebuilt `libghostty.a`, headers, and resources.
  Edits to either are wiped by the next ghostty update. If a change seems to need one,
  stop and ask.
- **A clean build prints a wall of warnings.** `Sendable` warnings from the vendored
  wrapper, a `@retroactive` warning from `Sources/Compat.swift`, and `ld:` version
  warnings from `deps/lib/libghostty.a` are all expected. Judge success only by the
  final line, `built: bin/Gutter`. Don't try to fix them.
- **Run the app bundle, never `bin/Gutter`.** The bare binary crashes on launch:
  ghostty's logger force-unwraps `Bundle.main.bundleIdentifier`.
- **There is no Xcode project and no test suite.** Verification is a successful compile
  plus a human clicking around. Ask for a manual check rather than claiming a behavior
  works.
- **Two keybind paths reach the same keys.** The menu (`MainMenu.swift` ->
  `AppDelegate` actions) and ghostty's own core keybinds (config -> libghostty ->
  `NSNotification` -> `GhosttyBridge`). `cmd-t` travels both, so a broken bridge can
  still look like a working app - test `cmd-w` too.
- **A new keybind lands in three places.** `Sources/MainMenu.swift` (the menu item),
  `Sources/ShortcutsWindowController.swift` (the ⌘? panel, written by hand), and the
  Keybinds table in `README.md`. All three are hand-maintained - nothing generates them
  from the menu - so a shortcut added to only one of them silently goes undocumented.
- **Self-contained.** The only external processes Gutter runs are macOS system
  binaries - `/usr/bin/git` for everything in `GitDiff.swift`, `/usr/bin/open`
  for the config file - and the only config it reads is its own at
  `~/.config/gutter/config`. Don't add a dependency on a developer tool that
  isn't part of macOS (`gh`, `jq`, `fzf`, a language runtime), don't read
  another tool's config or credentials, and don't make the app talk to the
  network. A machine with Xcode's command line tools and nothing else must run
  every feature. If something seems to need more, stop and ask - the answer is
  usually a smaller feature that uses git alone. `README.md` has an "Ideas, not
  built" section recording what was turned down this way and why.
- **Keep the comments.** They record hard-won fixes: fullscreen bar behavior, the first
  keystroke after launch, the `command` config quirk. Move them with the code they
  explain; don't drop them as noise.
