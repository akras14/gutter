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

### The exception: `vendor.sh` patches

`Vendor/` is off limits to hand edits, but `vendor.sh` may rewrite what it
copies. Each patch is a Python block with `assert`s on the text it expects, so
a ghostty update that moves the code fails the re-vendor loudly instead of
silently dropping the fix. Five exist today. Keep them few, keep them small,
and prefer a subclass in `Sources/` when one will do - see "The right-click
menu is trimmed, not rebuilt".

One of the five is not an embedder adaptation but a backport. Upstream's
`CachedValue` (the 500ms cache behind the surface's accessibility methods)
clears itself from a `Task` while the main thread reads it, and the racing
release of a Swift `String`'s storage aborts the process. It crashed Gutter on
2026-09-04 the first time macOS accessibility attached to a surface. The fix is
upstream's own (ghostty PR #13646, an `NSLock` around the value and the task
handle), merged after v1.3.1 and so absent from the released `libghostty` this
links. Drop the patch when the linked release contains it - the `assert`s will
still pass, so this is the only reminder.

### Not a product

No session restore, no test suite. For a full-featured terminal, use Ghostty or
iTerm2. Gutter is a window, a sidebar of sessions, and one live pane tree per
window, plus the few things that serve running several coding agents side by
side.

### Splits: declined, then reversed

This section used to read "declined, not deferred - don't re-propose this". The
reasoning was that a sidebar of full-height sessions covers the same need, and
that splits would be the largest change in the app.

The second half was wrong, and wrong for a checkable reason: `vendor.sh` already
copies everything ghostty's own split renderer is built from. `SplitTree` (the
tree, spatial focus, zoom, equalize, ratio resize), `SplitView` and its divider,
and `Ghostty.InspectableSurface` are all in `Vendor/` and were already compiling
into the app. What was missing was ~40 lines composing them, which is
`SessionTreeView.swift` - a near-copy of upstream's `TerminalSplitTreeView`,
minus the drag-and-drop zones.

The feature still grew `SessionManager` - per-pane state, the folds, seven tree
operations. What it did not grow is the terminal area, which came out 263 lines
smaller: see "The terminal area is ghostty's, not ours" below.

What holds from the original decision: a split lives **inside** a sidebar row.
One row is one session is a tree of panes. Panes are not sidebar rows, there is
no drag-a-pane-onto-a-pane, and split layout is not persisted across launches.

### Windows are whole copies of the app, not views of one

`⌘N` opens another window. It has its own sidebar, its own sessions, its own
changes window; the only thing two windows share is libghostty itself - one
`Ghostty.App`, one config, one process. A window is a `SessionManager`, and
nothing below the window knows there are others.

The sidebar scrolls, so this was never about how many sessions fit. It is about
screens and spaces: one window cannot be on two monitors, and a window is the
unit macOS lets you put on a second desktop, fullscreen on its own, or beside
an editor. Sharing one session list between two windows was considered and
turned down for the same reason it isn't tabs-of-tabs - two views of one list
means every selection, close and rename has to decide which view it happened
in, and the answer would be "the front one" every time, which is what separate
lists give for free.

Three things follow from one-`SessionManager`-per-window, and they are the whole
of the change:

- **Every menu action acts on the front window.** `AppDelegate.front` is the
  last window to become key, and `AppDelegate.sessions` is its list - which is
  why the menu actions read exactly as they did when there was only one.
- **`GhosttyBridge` routes by surface.** libghostty posts to the default
  NotificationCenter, so its actions are app-wide: one observer sees every
  window's ⌘T, ⌘D and ⌘W. The surface in the payload is the only thing that
  says where an action belongs, so every observer looks up the window owning it
  and applies the action there. An action with no surface - libghostty's
  app-target variants - falls to the front window.
- **The Dock badge moved to `AppDelegate`.** It used to be set from
  `MainWindowController`, on the argument that every session -> UI reaction
  lives there. With two windows that stops working: the tile belongs to the
  app, and two windows would each keep overwriting the other's count. It now
  sums every window, and View > Next Session Needing Attention walks across
  windows too - a badge that counts what the walk can't reach would strand the
  user on a number.

"Can the user see this pane" gained a third term at the same time, in
`SessionManager.isVisible`: the pane's window has to be on screen. With one
window "the app is active" was close enough - it is what marks a hand-off as
read. With two, a covered window's selected session would mark itself read on
every activation, and a bell in it would never light a dot at all.

Three smaller decisions:

- **Only the first window remembers its frame.** macOS gives a frame autosave
  name to one window and refuses it to the rest, which is also the cleanest test
  for "am I the first". The others open at the size of the window they were
  opened from, cascaded down-right, and copy its sidebar width. There is
  nothing to key a per-window frame on: the windows are interchangeable, and a
  saved frame per index would move whichever window happened to be second.
- **Quitting and closing a window ask first.** Reversed: a window used to
  close without asking, like the last window always had when closing it quit
  the app. Then an accidental ⌘Q took every session down, agents and all.
  Now ⌘Q, Quit from the Dock, the core's `quit`, ⇧⌘W, the close button and
  ⌥⇧⌘W (one question for all windows) each confirm, and every time - not
  only when something is running, because an idle agent waiting at its
  prompt is still the thing you'd lose. ⌘W (one pane) and ⌥⌘W (one session)
  still go through the core and confirm only when a pane has something
  running, so closing the last pane at an idle shell still closes the window,
  and with it the app, unasked. Logout and shutdown never ask: a prompt there
  would block the logout.
- **A window can be named** (File > Rename Window...), because the intended
  use is one window per project. The name is only the `NSWindow` title, but the
  title is what the Window menu and the Dock icon's window list are built from,
  and those lists are the reason to name anything - four windows all called
  "Gutter" are four identical rows.

  Three things it deliberately isn't. It is not derived from the session's
  directory: an auto-title tracking the selected tab would rewrite itself as
  you switch sessions or `cd`, and the one thing a project label has to be is
  stable. It is not persisted - nothing about a window is, not its sessions and
  not its split layout, so a remembered name would outlive everything it named.
  And it is not inherited by ⌘N: a second window called the same as the first
  is the problem, not the feature.

  No keybind, and no row in the ⌘? panel, which lists keys. It is a
  once-per-window action, and the keys near ⇧⌘R (Rename Tab) are worth more to
  the terminal. The rename is an `NSAlert` sheet rather than the in-place field
  the sidebar uses: the title bar is AppKit's, with no view to swap for an
  editor.

### The Dock is a way in, not just a way back

Two entry points beyond the menu bar, because the app is for leaving running
and coming back to:

- **The Dock icon's menu carries New Window** (`applicationDockMenu`). AppKit
  fills in the window list, Options and Quit; this is the one route into a new
  window without bringing Gutter forward first.
- **Clicking the Dock icon with no window open re-opens one**
  (`applicationShouldHandleReopen`). Closing the last main window quits Gutter,
  so this only fires while the changes or shortcuts window is holding the app
  open - and without it, that state has no way back to a terminal.

### The terminal area is ghostty's, not ours

Gutter used to host a bare `Ghostty.SurfaceView` in an AppKit container and
hand-write the things ghostty's own SwiftUI host already does. That inverted
when panes arrived: the pane tree is `Ghostty.InspectableSurface` inside
`SplitView`, both vendored, and each surface therefore arrives with its find bar
(`SurfaceSearchOverlay`), unfocused-pane dimming, resize overlay, progress bar,
bell border, pointer cursor and its own size, none of it Gutter's code.

That deleted `FindBarView.swift` outright, along with the container's find-bar
plumbing, its cursor rect and its `sizeDidChange` call. The rule this leaves
behind: **before writing terminal-area UI, look for it in `Vendor/` first.**
Anything ghostty draws inside a surface is almost certainly already there.

The cost, accepted knowingly: the terminal area is SwiftUI now, so the reversal
also applies to any "Gutter is AppKit end to end" reading of this document. The
window shell, sidebar and session model are still AppKit; the pane tree is not.

### The right-click menu is no longer trimmed

That menu comes from the vendored `SurfaceView.menu(for:)` and is ghostty's,
written for ghostty's window shell. Five of its items - the four splits and the
terminal inspector - posted notifications nothing observed, so they looked live
and did nothing. A `GutterSurfaceView` subclass filtered them out.

All five work now, and that subclass is gone:

- the splits, because `GhosttyBridge` observes `ghosttyNewSplit`;
- the inspector, because panes render through `Ghostty.InspectableSurface`,
  which handles `didControlInspector` itself and shows the vendored inspector -
  no Gutter code at all;
- "Change Tab Title...", which used to be hand-repointed at the sidebar rename,
  because `MainWindowController` is a real `BaseTerminalController` now and
  answers `changeTabTitle` itself.

The menu is entirely ghostty's again. Anything the wrapper adds to it later
arrives enabled by default, so when a ghostty update lands, right-click once and
check the new items do something here.

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
button on hover.

A row is a session and a session is a tree of panes, so every signal below is
read per pane and folded into the row. The folds are not all the same, and the
difference is the point: the row's **title** is the focused pane's, so it
doesn't flicker between panes, while **attention and working are OR-ed across
all of them**. Without the OR, an agent handing back in a pane you are not
looking at would never light the dot - which is the whole feature. "Seen" is
per pane too, so a pane hidden behind a zoom does not count as read.

The signals behind it, and why those and no others:

- **Claude Code's title.** It writes a braille spinner into the terminal
  title while working and prefixes the title with "✳" when it hands the
  session back. The spinner rides along in the row's title text for free;
  the "✳" prefix lights the dot. This is why Claude Code just works, and
  why tools that write a static title (opencode's `OpenCode`) show nothing
  - the title is the only text channel libghostty reports.
- **The bell.** A BEL on a non-selected tab lights the dot.
- **OSC 9;4 progress.** The ConEmu sequence Windows Terminal, iTerm2 and
  ghostty all read as "working"; libghostty surfaces it as the surface's
  `progressReport`. Only `.set` and `.indeterminate` spin. `.pause` and
  `.error` are hand-offs, not work, and light the dot alongside a cleared
  report - the same "handed back" edge as "✳". Reading a live report as
  "working" regardless of state would spin through exactly the moment the
  user is wanted, since `.pause` is how a tool says it is asking something.

What was considered instead: opencode's attention notifications (OSC 99 /
777 desktop notifications) were rejected as the spinner channel - they
fire only on completion, ghostty 1.3.1's parser drops OSC 99 entirely (no
parser state), and the vendored wrapper turns what remains into a macOS
banner, not sidebar state.

### The fourth signal is a config line, seeded not forced

A plain shell reports none of the three above, so a build or a test run in a
background tab lights nothing. ghostty already has the answer:
`notify-on-command-finish = unfocused` makes a command that ran longer than
five seconds post a bell when it finishes in an unfocused surface, and the
vendored wrapper's `commandFinished` posts exactly the `.ghosttyBellDidRing`
the dot already listens for. Nothing to build; the default is `never`, so the
only problem was that nobody would know to turn it on.

So Gutter writes it into the config file it creates on a machine that has none
(`AppDelegate.ensureConfigFile`), commented, alongside the `config-file` line
for inheriting a ghostty config.

A seed, not an override. The embedder config `main.swift` writes loads *after*
the user's file and wins over it - right for the keybinds it carries, wrong for
a default, which has to be something the user can edit or delete. The cost is
that a seed only reaches a machine that hasn't run Gutter before; an existing
config keeps whatever it says, and Gutter never rewrites it.

What it does not do is make noise. `bell-features` - the system alert sound,
the dock bounce, the 🔔 title prefix - is handled in ghostty's own app target,
which `vendor.sh` doesn't copy, and this path posts the notification directly
anyway. The sidebar dot and the Dock badge are the whole effect. Turning the
`notify` action on (`notify-on-command-finish-action = bell,notify`) adds a
macOS banner, which is the wrapper's `showDesktopNotification` and does work
here.

### opencode reports nothing on its own

opencode shows no spinner and no dot, and it can't be made to with the
channels above. A full turn captured off the pty (`script -q out opencode`,
opencode 1.18.27) emits, in total: `OSC 0;OpenCode` three times - a static
title that never changes while working - colour queries (`OSC 4/10/11/14-19`),
an `OSC 99` capability *probe* (not a notification), `OSC 66` text sizing,
and an `OSC 1337;Capabilities` probe. There is no `OSC 9;` of any kind and
no standalone BEL: all 38 BELs in the capture are OSC terminators. The same
holds statically - zero `]9;` bytes in the 144MB binary.

The tab indicator opencode does light up in iTerm2 is not a progress
protocol. The capture's one bulk signal is 508 `CSI ?2026h/l`
synchronized-update pairs in a single turn: opencode simply repaints
constantly, and iTerm2 derives its indicator terminal-side from output
activity. Nothing is being reported, so there is nothing for a sidebar to
read. Chasing iTerm2 parity means adopting its mechanism, not its protocol.

The fix is upstream of Gutter and already exists. The community plugin
`opencode-terminal-progress` emits real OSC 9;4 from opencode's plugin API,
keyed off `TERM_PROGRAM`, which libghostty sets to `ghostty`
(`termio/Exec.zig`) - so Gutter's surfaces are detected with no code on our
side. It maps busy to `.indeterminate`, waiting-for-input to `.pause` and
failure to `.error`, which is where the state mapping in the bullet above
comes from. Asking opencode to emit this natively is a dead end worth not
re-walking: it has been requested (anomalyco/opencode #24807) and the plugin
proposed for the ecosystem page (#16453), and both were auto-closed as stale
rather than judged; #44076 is the live one.

Sniffing output activity that way is still not done here, but the reason is
narrower than "impossible": libghostty *does* have an output-driven signal,
`GHOSTTY_ACTION_RENDER` (`deps/include/ghostty.h`). It's the vendored
wrapper that drops it - `Ghostty.App.swift`'s action switch handles
`RENDER_INSPECTOR` and `RENDERER_HEALTH` but never `RENDER` - so `Sources/`
can't see it. Reaching it means another `vendor.sh` patch, in the same style
as the five already there. The design objection stands on its own: a render
signal fires per frame with no idle/busy distinction, so every row with a
repainting TUI in it would spin forever. Debouncing it is guessing at
liveness, which is what a real report exists to avoid.

One caveat lives in the vendored wrapper, not here: a progress report that
goes unrefreshed for 15s is cleared (`SurfaceView_AppKit.swift`), which
reads as the working -> idle edge. Emitters are expected to re-assert the
report while busy; a send-once emitter shows a 15s spinner and an early
dot.

### The count leaves the window

The dot is only visible to someone looking at the sidebar, which is the one
place you are not when the app is doing its job: the point of starting five
agents is to go and do something else. So the same state - `needsAttention`,
counted across sessions - is on the Dock icon as a badge, and View > Next
Session Needing Attention walks the sessions carrying it.

No new signal is involved. The badge counts exactly what lights the dots, so
everything above about what does and doesn't light one applies unchanged; if a
tool doesn't light a dot it doesn't raise the count either. The badge counts
rows, not panes: two panes wanting you in one session is still one.

Walking to a session also lands you on the *pane* that raised it, un-zooming if
a zoom was hiding it. With panes the dot no longer says where in the row to
look, so leaving focus where it was would hand you a row and a hunt.

Two things were considered and turned down:

- **Bouncing the Dock icon** (`NSApp.requestUserAttention`). With several
  agents running, a bounce per hand-off is near-constant motion, and the
  informational variant's single bounce is missed as easily as the badge while
  costing an interruption. A badge is read on the next glance at the Dock,
  which is when the user is ready to look.
- **A keybind for the jump.** VS Code has no counterpart to copy - its nearest
  idea is `F8`, go to next problem - so it would have to be invented, and every
  binding Gutter takes is a key the terminal no longer gets. The badge already
  says *that* something wants you and the sidebar says *which*, so the menu
  item only has to be clickable. It is also the first menu item here that
  disables itself: `AppDelegate.validateMenuItem` greys it when nothing is
  waiting, which makes the menu a second readout of the same count.

The badge is set from `AppDelegate`, summed over every window. It started in
`MainWindowController`, on the argument that the controller owns every session
-> UI reaction already; a second window ended that, since the tile belongs to
`NSApp` and two windows would overwrite each other's count. `SessionManager` is
still the model and still holds no AppKit policy - it only counts.

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

### Find searches one pane, and says which

The changes window has its own find bar (⌘F while it is key), because whole
files raise the question folded hunks never do: where else in this file is
that name used? The Edit menu's Find items are the same ones the terminal
uses; `AppDelegate` sends them to the changes window while it is key.

Four decisions, each against an easier option:

- **One pane at a time, meld's shape.** The first cut searched both panes at
  once, and was a surprise on first use. A diff question is usually about one
  side - "where is this in the old file?" - and a line changed on both sides
  counted twice. The bar searches the pane last clicked into, or the one
  picked in its toggle; it starts on the worktree.
- **The active pane is marked four ways while the bar is open:** the toggle,
  an accent border around the pane, its caption in the accent color, and the
  field's placeholder ("Find in Working tree"). Without it, "No matches" reads
  as a bug when the string is sitting in the other pane. With the bar closed
  nothing is marked.
- **Hand-written, not `NSTextFinder`.** AppKit's finder would give each pane
  its own bar, and it searches the rendered text. The panes' lines carry line
  numbers and trailing padding, so "12" would light up line numbers and a run
  of spaces would match every short line. This searches the rows instead.
- **The query stays while you switch files and refresh.** Once you know what
  to look for, the next file is often where else it is used. Opening a file
  lights its matches but doesn't scroll. Stepping starts from the top of the
  panes, so ⌘G still takes you to the first match below where you are.

Matches are marked on the change-map strip in yellow, narrower than a change
mark, so a match inside a change still shows the change's color. It searches
one file, not every changed file: the file list already shows which files
changed, and a cross-file search would need a results list the window has no
room for.

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

### The branch base is picked, not only inferred

Inferring the base from `origin/HEAD` assumes a PR targets the default branch.
That is wrong for a stacked PR based on another branch, and for cases no PR
host knows about, like diffing against a release branch. So branch mode carries
a popup beside the toggle: the inferred default first, then every other branch,
most recently committed to first - the branch you would stack on is one you
were just working on. Capped at 40, because a repo that has been alive for
years has hundreds of refs and a menu that long is a list, not a picker.

The pick is remembered per repo root. It belongs to the repo rather than to a
visit to it - a stacked branch keeps the same parent for as long as it is being
worked on, and re-picking on every open would make the picker worse than the
inference it replaces. It also has to be keyed that way: the diff window is a
single reused window, so a pick held on the window alone would leak the last
repo's base into the next one.

The inference stays, as the fallback and as the self-healing path. A remembered
branch that has since been deleted is not an error - it resolves back to the
default, and the popup follows what resolved rather than showing a stale name.

The tempting shortcut is `gh pr view --json baseRefName`, which reports the real
base. Rejected: it would make Gutter depend on a tool that isn't part of macOS,
needs its own auth, and only answers for GitHub. See "Self-contained" above.

### The header says PR, not merge base

Branch mode was first labelled in git's own terms - "vs merge base with
origin/master at 4240eb3". It was accurate and it did not work. "Merge base"
reads as one fixed thing, so a picker offering several branches beside it looks
like it is offering several merge bases to choose between, and the honest
question it produces is "which of these is *the* merge base?". There isn't one:
a merge base is per pair, and this branch has a different one with every branch
in the list.

So the header states the outcome instead - `PR into origin/master` - and the
left pane is captioned with the base branch, the way GitHub captions the left
side of a PR diff. The merge base, the short sha and the "N commits since"
count all still exist and are all in the label's tooltip, which is where they
belong: they answer "why these files?", which is a second question, asked less
often than the first.

The window is used to answer "is this what my PR will show?". It should be
readable without knowing what git calls the operation.

### The file count owns the one difference from GitHub

Branch mode is `merge-base(base, HEAD)` against the **worktree**, where GitHub
compares it against the pushed head commit. Everything else matches - the file
lists are identical when the tree is clean, which was checked against a real
branch. The gap is uncommitted and untracked work, which Gutter deliberately
includes (see "Branch mode compares against the merge base" above: an agent
that commits mid-review must not blank the diff).

A count that silently disagrees with the PR is worse than either behavior, so
the header says which files those are: `5 files (2 not yet committed)`. It
costs a second status call, taken only in branch mode and only when there is
something to count.

### The header's controls don't move

The header first packed everything from the left: summary, toggle, picker,
chevrons, Refresh. The summary changes length on every mode switch, file
count and refresh (a reload even reset it to the bare path while loading), so
the controls after it slid sideways all the time - including the toggle and
the chevrons, the ones clicked repeatedly.

Now the controls hang off the trailing edge and the summary takes what is
left, truncating from the head. Anything that changes width sits to the left
of the fixed controls: the base picker, which appears with branch mode and
sizes to its ref, is the leftmost control, so clicking Branch doesn't move the
toggle out from under the pointer. Refresh is sized for its stale title
("Refresh •") from the start. The summary stays up while a reload of the same
directory runs, and the pane captions truncate rather than letting a long ref
name widen the panes and push the file list's divider.

### It says when it has gone stale, and doesn't reload itself

The window is open while an agent is writing, so what it shows goes out of date
under the reader - and until it says so, the only symptom is a diff quietly
describing a tree that has moved on. A `RepoWatcher` (FSEvents on the repo
root, live only while the window is open) puts a dot on the Refresh button when
something changes.

It stops there. A reload re-renders both panes from the top, and the panes hold
whole files - so refreshing behind someone reading a long file would lose their
place, which is exactly what `cmd-[` / `cmd-]` and the change map exist to
protect. The hint is the new information; `cmd-r` stays the only thing that
changes what is on screen. If a reload ever preserved scroll position, this
would be worth revisiting.

Two filters stand between the raw event stream and that dot, and both are
load-bearing:

- **Most of `.git` is ignored.** `git status` and `git diff` rewrite the
  index's stat cache, so a load's own git calls fire events - watching the
  index would relight the dot moments after every refresh. What counts inside
  `.git` is what a commit or a checkout moves: `logs/`, `refs/`, `HEAD`,
  `packed-refs`. That case matters most, since in uncommitted mode a commit
  empties the diff outright.
- **Ignored paths don't count.** A repo with a dev server or a `node_modules`
  writes constantly to paths git is told to ignore, and a dot that is always lit
  is a dot nobody reads. `GitDiff.containsUnignored` asks
  `git check-ignore -z --stdin` about the batch - one small git call per burst,
  not a scan of the repo.

Verified against a scratch repo: a tracked edit lights it, a write under an
ignored directory doesn't, a `git status` doesn't, a commit does.

The dot is path-based, not content-based, so writing a file with the content it
already had still lights it. Asking whether the *diff* changed means diffing,
which is the reload this deliberately doesn't do.

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

## Only what you are looking at renders

libghostty draws every surface it holds, at full render-thread QoS, until told
otherwise. Gutter keeps every pane's surface alive forever and swaps which
session's tree is in the view hierarchy, so without a signal every background
session paints frames into a detached layer for as long as its agent is busy,
and each one's window-sized Metal drawables stay resident because they keep
being presented. Measured on 11 sessions: 45 IOSurfaces at 21.4MB each, 964MB
of a 1.3GB footprint. Panes multiply that, which is why this is per pane and
not per session.

The signal is `ghostty_surface_set_occlusion`. ghostty's own shell makes the
call from `BaseTerminalController.windowDidChangeOcclusionState` - an app-target
file `vendor.sh` doesn't copy, since it only copies the wrapper - so Gutter
inherited the C API and none of its callers, and every surface stayed at the
core's default of visible.

`SessionManager.syncOcclusion` is that call, over all three parts of "is anyone
looking at this pane": its session is selected, the window is on screen
(`MainWindowController.windowDidChangeOcclusionState`), and no zoom is hiding
it. Ghostty only has the window half, because its tabs are separate windows;
Gutter's are not, so selection and zoom are ours.

The zoom part is easy to lose: `SplitTree.inserting` and `resizing` both return
a tree with the zoom cleared (`SplitTree.swift:129,332`), so a resize while
zoomed makes hidden panes visible again. Every structural change therefore goes
through `SessionManager.treeChanged`, which resyncs occlusion - never assign
`session.tree` and skip it.

This is a rendering signal and nothing more. `renderer/Thread.zig` drops the
thread to `.utility` and skips the draw; the pty keeps running, the terminal
keeps updating, and the core queues a redraw the moment a surface becomes
visible again. Everything the sidebar reads - titles, bells, progress - comes
off the terminal, not the renderer, so an unselected session still lights its
dot. It does not free the drawables already allocated, only stops feeding them,
which lets macOS page out the idle ones.

## Open

Raised, not answered.

### No click target for a new session

There is no "+" in the toolbar or the sidebar; `cmd-t` is the only way to open
a session (the View menu item plus ghostty's own `super+t=new_tab` keybind). A
toolbar "+" and a sidebar footer button have both been offered and neither was
taken up.
