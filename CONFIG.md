# Config

Gutter reads `~/.config/gutter/config`. It is ghostty's config file format, so
every option in [ghostty's docs](https://ghostty.org/docs/config) works here -
but that is a reference of several hundred settings, and this is the short list
that actually earns its place in a Gutter config.

`⌘,` opens the file (and the launchers file beside it), `⇧⌘,` reloads without a
restart. Syntax is `key = value`, one per line, `#` starts a comment.

Gutter never loads ghostty's own config files. To inherit yours:

```
config-file = ?~/.config/ghostty/config
```

The `?` means "skip if missing", so the line is safe on a machine with no
ghostty install.

## A config to start from

```
# Sessions start here when they don't inherit from another tab.
working-directory = ~/projects

theme = Builtin Tango Dark
font-family = "SF Mono"
font-size = 16

# Light a session's sidebar dot when a long command finishes in a tab you
# aren't looking at.
notify-on-command-finish = unfocused

# Selecting text puts it on the clipboard ⌘V reads.
copy-on-select = clipboard

# ⌘N opens a window in ghostty; Gutter has one window, so it does nothing.
keybind = super+n=unbind
```

## What each one is for

### `notify-on-command-finish`

Default `never`. Set it to `unfocused` and a command that ran for five seconds
or more lights the sidebar dot - and the Dock badge - when it finishes in a tab
you are not looking at.

This is the signal a plain shell has. Coding agents report themselves (Claude
Code writes its status into the terminal title, and anything speaking OSC 9;4
progress is read too), but a `make`, a test run or a long clone reports nothing
on its own, and this is what covers them.

- It needs shell integration to know when a command starts and ends. Gutter
  bundles it, so it works out of the box for zsh, bash and fish.
- `notify-on-command-finish-after = 30s` changes the five seconds.
- It makes no sound and doesn't bounce the Dock. For a macOS notification
  banner as well, add `notify-on-command-finish-action = bell,notify`.

New installs get this line already, in the config file Gutter creates on first
launch. An existing config is never rewritten, so add it by hand if you have
been running Gutter for a while.

### `copy-on-select`

Default `true`, which on macOS is not what it sounds like: it copies to a
private pasteboard that only middle-click paste reads, and ⌘V sees nothing.

```
copy-on-select = clipboard
```

is the one that also writes the system clipboard, so any selection - drag,
double-click a word, triple-click a line - is ready to paste. The selection
stays visible after copying.

The cost is that selecting text replaces whatever was on your clipboard, which
is why ghostty doesn't ship this as the macOS default.

### `theme`, `font-family`, `font-size`

463 themes ship inside the app. To see the names:

```sh
ls /Applications/Gutter.app/Contents/Resources/ghostty/themes
```

Use one by name: `theme = Builtin Tango Dark`. `font-thicken = true` (default
off) helps a thin font on a non-Retina display.

### `working-directory`

Where a session starts when it has nowhere else to start. `⌘T` normally opens
in the current tab's directory instead - that is
`tab-inherit-working-directory`, on by default - so this is the fallback for
the first session of a launch.

### The cursor, and shell integration

ghostty's shell integration turns the cursor into a blinking bar at the prompt,
which quietly overrides whatever `cursor-style` says. Turn that one feature off
and the cursor settings stick:

```
shell-integration-features = no-cursor
cursor-style = block
cursor-style-blink = false
```

### `keybind`

Same syntax as ghostty - `keybind = super+n=unbind`, `keybind = super+d=...` -
and it is the one setting where Gutter and ghostty genuinely differ, because
Gutter implements less than the core can ask for.

**Actions that do nothing here.** Splits, the command palette, the quick
terminal and new-window are not implemented - one window, one surface - so the
core's keys for them are dead keys. `⌘N` is the one you'll actually hit:
ghostty binds it to `new_window`, and in Gutter nothing happens. Unbind it if a
silent ⌘N bothers you:

```
keybind = super+n=unbind
```

**Five keys Gutter claims**, which your config can't take back, because its
overrides load *after* your file:

| Key | What Gutter does with it |
|---|---|
| `⌘T` | `new_tab` |
| `⌘9` | `goto_tab:9` - the core binds only 1-8 |
| `⌘,` `⇧⌘,` | unbound from the core, so Gutter's own config menu items get them |
| `⇧⌘T` | unbound from the core, so File > New Request gets it |

Everything else is yours.

The rest of Gutter's own keys are menu items, not core keybinds, so they don't
appear in this file at all - `⇧⌘/` (Help > Keyboard Shortcuts) lists them.

## The other file: launchers

The tools `⇧⌘T` can start a request with live in `~/.config/gutter/launchers`,
not in the config above - libghostty parses the config and rejects keys it
doesn't recognize, so Gutter's own keys need their own file. Same
`key = value` syntax:

```
launcher = claude
launcher-for ~/projects = pclaude
folder = ~/src/screenings_app
```

First `launcher` is the default; `launcher-for` gives a folder tree its own,
longest matching path winning. `⌘,` opens this file too, and it is created with
a commented template on first launch.

## When something doesn't take

Config errors are reported in a dialog on `⇧⌘,` and logged at launch:

```sh
/usr/bin/log stream --style compact --predicate 'process == "Gutter"'
```

Look for `config error:` lines. A theme that isn't found is the common one, and
usually means the app bundle is missing its resources - rebuild with
`make-app.sh`.
