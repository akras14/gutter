# GhosttyTabs

A small native macOS terminal app with a vertical tab sidebar, embedding
[libghostty](https://ghostty.org) (ghostty **v1.3.1**) as a static library.

One window, one collapsible sidebar. Every session is a real libghostty surface -
Metal rendering, PTY handling, VT emulation, input/IME and config loading all come
from ghostty's core and its own Swift wrapper. The app itself is ~700 lines of
AppKit (window shell, sidebar, session manager). No Xcode project: everything
builds with `swiftc` + scripts.

Your existing Ghostty config drives it: theme, font size, working directory and
keybinds are loaded from
`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
(falls back to the standard XDG locations).

See `BUILDING.html` for the rendered setup notes - prerequisites, build steps, layout, gotchas.

## Layout

| Path | Purpose |
|---|---|
| `Sources/` | App code: `AppDelegate` (window/menus), `SessionManager` (sessions, tabs), `SidebarViewController`, `TerminalShell.swift` (split view + surface container) |
| `Sources/Shims.swift` | Stub types the vendored wrapper `as?`-casts to (no-op in this app) |
| `Sources/Compat.swift` | Shims for Swift-overlay APIs missing from the CommandLineTools toolchain |
| `Vendor/` | Swift wrapper copied from the ghostty checkout by `vendor.sh` (SurfaceView with input/IME, config, app runtime) |
| `vendor.sh` | Re-copies + patches the wrapper (patches live here, reproducible) |
| `build.sh` / `make-app.sh` | Build the binary / assemble `dist/GhosttyTabs.app` |
| `Info.plist` | Bundle metadata (bundle id, min macOS 13) |

## Requirements

- macOS 13+ (built and tested on 26.x, arm64)
- Xcode installed at `/Applications/Xcode.app` with the **Metal Toolchain**
  component (Xcode Settings -> Components)
- The ghostty checkout at `~/projects/ak/ghostty` (tag `v1.3.1`, with a completed
  `zig build` - see "Rebuilding libghostty")
- Zig 0.15.2 at `~/projects/ak/.tooling/zig-aarch64-macos-0.15.2/` (only for
  rebuilding libghostty)

## Build & run

```sh
cd ~/projects/ak/GhosttyTabs
./build.sh      # compile app + vendored wrapper, link libghostty
./make-app.sh   # assemble dist/GhosttyTabs.app (bundles themes + shell integration + terminfo)
open dist/GhosttyTabs.app
```

`build.sh` compiles a small ObjC helper, runs `swiftc` over `Sources/` +
`Vendor/` (the C API is bridged via ghostty's `module.modulemap`), and links the
static `libghostty` archives from the ghostty zig-cache. Always run the app from
the bundled `.app` - the bare binary crashes because ghostty's logger force-unwraps
`Bundle.main.bundleIdentifier`.

## Developing

- **App code**: edit `Sources/`, then `./build.sh && ./make-app.sh`. There is no
  Xcode project; iterate with the scripts.
- **Fast syntax check** (no linking): run the `swiftc -typecheck` command inside
  `build.sh` by hand, or just run `./build.sh` - it is fast once the archives are
  repaired.
- **Vendored wrapper**: to pull in ghostty changes, re-run `./vendor.sh`. The
  patches applied on top of upstream (missing imports, a ForEach rewrite, the
  `goto_tab` performability guard, an embedder config-file hook) are asserted
  with occurrence counts - they fail loudly if upstream drifts, and then need a
  look.
- **Runtime logs**: ghostty logs through os.Logger. Watch with
  `/usr/bin/log stream --style compact --predicate 'process == "GhosttyTabs"'`
  (config errors, renderer health, spawn failures all show up there).
- **Keybind overrides** (`cmd+t=new_tab`, `cmd+9=goto_tab:9`) are injected via a
  temp config file from `main.swift` through `Ghostty.Config.embedderConfigFile`.
  The core has no default `cmd+t` on macOS (upstream handles it in their app
  menu), and goto_tab only defaults to 1-8.
- Don't override `command` in config overrides: repeated `command` keys append
  to the default argv instead of replacing it.

## Rebuilding libghostty (rare)

Only needed when the ghostty core changes:

```sh
cd ~/projects/ak/ghostty
PATH="$HOME/projects/ak/.tooling/shim-bin:$PATH" \
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
```

The `shim-bin` xcrun wrapper points zig's SDK detection at a shadow SDK
(`~/projects/ak/.tooling/MacOSX26.5-arm64.sdk`) whose tbds declare
`arm64-macos` - macOS 26 SDKs dropped it and zig 0.15.2's linker requires it.
After rebuilding, run `./build.sh` once: it detects whether Xcode 26.x's
`libtool` dropped the unaligned core member from the fat archive and re-pads the
zig-cache archives with Apple's `ar` before linking.

## Sharing the binary

`dist/GhosttyTabs.app` is self-contained (static libghostty, themes, shell
integration) - just zip it:

```sh
cd ~/projects/ak/GhosttyTabs/dist && zip -r GhosttyTabs.zip GhosttyTabs.app
```

Recipients should know:

- **arm64 (Apple Silicon) only**, macOS 13+.
- The app is **ad-hoc signed** (no developer certificate). On another Mac,
  Gatekeeper will block the first launch: right-click -> Open, or clear the
  quarantine flag with `xattr -cr GhosttyTabs.app`.
- It reads the recipient's own Ghostty config; without one it runs with
  ghostty's default theme.
- The embedded libghostty is MIT-licensed (c) Mitchell Hashimoto /
  ghostty contributors; keep that attribution if you redistribute.

## Keybinds

| Keys | Action |
|---|---|
| `cmd-t` / `cmd-w` | New tab / close tab (ghostty core keybinds -> notifications -> sidebar) |
| `cmd-1..9` | Select tab N |
| `ctrl-tab` / `ctrl-shift-tab` | Next / previous tab |
| `ctrl-cmd-S` or toolbar button | Toggle sidebar |

## Troubleshooting

- **Config errors at launch**: check the unified log (command above) for
  `config error:` lines. Theme not found usually means the bundled themes are
  missing from the app's `Contents/Resources/ghostty/themes` - re-run
  `make-app.sh`.
- **App quits when the last tab closes**: intentional (matches Terminal.app
  behavior).
- **No tab titles**: titles come from the shell (your zsh config reports cwd);
  a fresh shell shows the ghost fallback until the first prompt draws.
