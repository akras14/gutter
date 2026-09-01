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
- **Keep the comments.** They record hard-won fixes: fullscreen bar behavior, the first
  keystroke after launch, the `command` config quirk. Move them with the code they
  explain; don't drop them as noise.
