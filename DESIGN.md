# Design decisions

Why Gutter is shaped the way it is, and what was deliberately turned down.
Read this before proposing a feature, changing behavior, or reaching for a new
dependency - most of the obvious ideas have already been considered here, and
several were rejected for reasons that aren't visible in the code.

`README.md` describes what Gutter does. `CLAUDE.md` covers how to build it
without breaking it. This file is the *why*.

## Scope

### Not a fork

Gutter links the released `libghostty` static library and brings its own AppKit
shell. Following upstream means auditing one file (`GhosttyBridge.swift`) for
API drift, not rebasing a patched copy of ghostty's source.

This is why `Vendor/` and `deps/` are off limits: they are copied verbatim by
`vendor.sh` and the next ghostty update overwrites them. A fix that seems to
need an edit there is a fix in the wrong place.

### Not a product

No splits, no session restore, no test suite. For a full-featured terminal, use
Ghostty or iTerm2. Gutter is one window, a sidebar of sessions, and one live
terminal surface, plus the few things that serve running several coding agents
side by side.

### Splits: declined, not deferred

Discussed and explicitly turned down. A sidebar of full-height sessions covers
the same need, and splits would be the largest change in the app: the single
surface in `MainSplitViewController` becomes a tree, taking `SessionManager`,
the sidebar rows, and focus handling with it.

Don't re-propose this.

### Not competing with iTerm

iTerm2 has had left-side tabs for years and wins on features. Gutter's niche is
ghostty's speed and renderer, vertical tabs, and a codebase small enough to own
outright - it began as a "can a separate app embed libghostty?" experiment and
is still framed as a learning project first.

cmux, a ghostty-based alternative, was tried and disliked on feel. Wanting to
own the experience is the actual motivation, so "tool X already does this" is
not on its own an argument against building something here.

### Keybinds follow VS Code

When picking a new keyboard shortcut, look up VS Code's binding for the same
idea and reuse it - that's where the muscle memory comes from. `ctrl-shift-g`
for the diff window is VS Code's Show Source Control; `cmd-b` for the sidebar
was chosen the same way. Propose the VS Code equivalent first and say so; only
invent a binding when VS Code has no counterpart.

### Self-contained

The only external processes Gutter runs are macOS system binaries -
`/usr/bin/git` for everything in `GitDiff.swift`, `/usr/bin/open` for the
config file - and the only config it reads is its own at
`~/.config/gutter/config`.

So: no dependency on a developer tool that isn't part of macOS (`gh`, `jq`,
`fzf`, a language runtime), no reading another tool's config or credentials, no
network. A machine with Xcode's command line tools and nothing else must run
every feature.

When a feature seems to need more, the answer is usually a smaller feature that
uses git alone - see the diff base picker below for how that played out.

## The sidebar status slot

Each row's leading slot shows one of three things: a spinner while the
session is working, an orange dot when it wants the user, the row's close
button on hover. The signals behind it, and why those and no others:

- **Claude Code's title.** It writes a braille spinner into the terminal
  title while working and prefixes the title with "✳" when it hands the
  session back. The spinner rides along in the row's title text for free;
  the "✳" prefix lights the dot. This is why Claude Code just works, and
  why tools that write a static title (opencode's `OC | <session>`) show
  nothing - the title is the only text channel libghostty reports.
- **The bell.** A BEL on a non-selected tab lights the dot.
- **OSC 9;4 progress.** The ConEmu sequence Windows Terminal, iTerm2 and
  ghostty all read as "working"; libghostty surfaces it as the surface's
  `progressReport`. A live report shows the spinner, and the report
  clearing lights the dot - the same "handed back" edge as "✳".

What was considered instead: opencode's attention notifications (OSC 99 /
777 desktop notifications) were rejected as the spinner channel - they
fire only on completion, ghostty 1.3.1's parser drops OSC 99 entirely (no
parser state), and the vendored wrapper turns what remains into a macOS
banner, not sidebar state. Sniffing output activity (iTerm2's tab spinner)
is out: libghostty exposes no output callback, and per-frame redraws would
keep every row spinning forever.

One caveat lives in the vendored wrapper, not here: a progress report that
goes unrefreshed for 15s is cleared (`SurfaceView_AppKit.swift`), which
reads as the working -> idle edge. Emitters are expected to re-assert the
report while busy; a send-once emitter shows a 15s spinner and an early
dot.

## The diff view

### Side-by-side, meld-style

The first cut was unified colorized text and was rejected on sight: the ask was
"more of a meld experience". Two scroll-synced panes is the standard for diff
UI here.

This is also why `GitDiff` asks git only for *file contents* (`git show
<rev>:path` and the file on disk) and never for a rendered diff - a unified
diff can't be laid out in two aligned columns without being un-merged again.
The alignment is a plain LCS over lines, the same shape meld uses.

### Whole files, not folded context

The panes show the entire file, not a few lines of context around each hunk.
This is deliberate and wanted. The change-map strip between the panes, plus
`cmd-[` / `cmd-]` to jump between changes, is the answer to finding edits in a
long file.

Don't propose collapsing unchanged regions to make changes easier to find. That
problem is already solved a different way.

### Branch mode compares against the merge base

The diff has two comparisons, chosen by a toggle in the window header:

- **Uncommitted** - `HEAD` vs the worktree.
- **Branch** - the merge base with the default branch vs the worktree.

Branch mode exists because Gutter is for running several coding agents at once,
and `HEAD` is the wrong baseline for that: the moment an agent commits, an
uncommitted-only diff goes blank and the work you wanted to review disappears.

It compares against the **merge base**, not the branch tip. A two-dot diff
against the tip would also show every commit the default branch gained since
you branched, backwards, as deletions you never made.

The base ref comes from `origin/HEAD`, falling back to `origin/main`,
`origin/master`, `main`, `master` - git only writes `origin/HEAD` at clone
time, so plenty of repos don't have one.

Both modes compare against the worktree, so both include whatever is still
dirty.

## Firing off requests

`cmd-shift-t` opens a small sheet - folder, tool, prompt - and runs the tool in
a new tab that does *not* take focus. It exists because the common case while
running an agent is thinking of a second thing to ask, in the folder you are
already in, without losing the tab you are in.

### Not "clone this session"

The first shape proposed was a clone button: duplicate the current session,
same folder, same command. Two things killed it. libghostty exposes no pid, no
tty and no running command for a surface (`command_finished` carries an exit
code and a duration, nothing else), so "same command" can't be discovered - and
reading it out of `ps` would mean guessing which process belongs to which
surface. And once `cmd-t` inherits the working directory, cloning the *folder*
stopped being worth a button.

What was left is the part a terminal can't guess: which tool. So it's a
launcher, not a clone.

### A second config file

Launchers live in `~/.config/gutter/launchers`, not in
`~/.config/gutter/config`. That file is parsed by libghostty, which diagnoses
keys it doesn't recognize, so Gutter cannot add its own to it. Same
`key = value` syntax so the two read alike.

A folder can claim a default tool (`launcher-for ~/projects = pclaude`), longest
matching path first. The sheet preselects it and the popup is the override -
the folder usually knows which harness you want, but not always.

### The folder is a list, not a text field

Typing a path is the rare case, so the sheet offers a popup instead: the folder
you are in, then the folders your other tabs are in, then any `folder =` lines.
The open tabs are what make the list worth having - a config-only list would
hold two tree roots and nothing you'd actually run in. A folder that is in no
tab and no config can't be picked, and the answer to that is a tab: `cmd-t`,
`cd`, `cmd-shift-t`.

### Typed into the shell, not spawned as the command

The tool goes in as `initialInput` - text written into the session's shell -
rather than the surface's `command`. Two reasons, and the first is decisive:
`command` execs directly or through `/bin/sh -c`, and neither loads an
interactive shell, so a tool that is a shell alias (`pclaude` is
`CLAUDE_CONFIG_DIR=... claude`) cannot be run that way at all. The second is
that a `command` surface dies when the command exits, while a shell one leaves
you at a prompt in the right folder, which is where you want to be when the
agent finishes.

The prompt is single-quoted before it goes in. It is the user's prose, so
apostrophes, quotes and `$` in it must never reach the shell as syntax.

### The new tab doesn't take focus

`newSession(select:)` exists for this. The pty spawns in `SurfaceView.init`, at
the 800x600 frame the view starts with, so a session that is never shown still
runs - the sidebar row lights its dot when the agent wants you, which is the
reason for wanting a tab rather than `claude --bg` in the first place.

### cmd-shift-t had to be unbound in ghostty first

VS Code has no "new terminal with profile" binding to copy, so this one is
invented. With a focused surface the ghostty core claimed the key and the menu
item never fired, while the same keystroke worked with the sidebar focused -
the same trap as `super+,`. `main.swift` unbinds it.

## Ideas, not built

Considered and deferred, with the reasoning kept so it doesn't have to be
rebuilt from scratch.

### Choose the diff base

Branch mode assumes a PR targets the default branch, which is wrong for a
stacked PR based on another branch. The fix is to let the base be picked rather
than inferred: the Branch side of the toggle becomes a small popup of candidate
refs - default branch first, then other local and remote branches - remembered
per repo. That also covers cases no PR host knows about, like diffing against a
release branch.

The tempting shortcut is `gh pr view --json baseRefName`, which reports the real
base. Rejected: it would make Gutter depend on a tool that isn't part of macOS,
needs its own auth, and only answers for GitHub. See "Self-contained" above.

## Open

Raised, not answered.

### No click target for a new session

There is no "+" in the toolbar or the sidebar; `cmd-t` is the only way to open
a session (the View menu item plus ghostty's own `super+t=new_tab` keybind). A
toolbar "+" and a sidebar footer button have both been offered and neither was
taken up.
