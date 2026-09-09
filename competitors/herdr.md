# Herdr

A background daemon that owns coding agents' terminals so they keep running
when you don't. Researched 2026-09-06 against **v0.8.2**, commit `4b5e9bd`.

Read this alongside `../DESIGN.md`. Nothing here is a decision - where a
finding bears on one of Gutter's, this file says which entry it touches and
leaves the entry alone. Open questions are at the bottom.

Claims are grouped by how they were checked: their marketing, their source, and
our reading of both. Don't promote one to another without re-checking.

## Bottom line

Herdr is not a competitor at Gutter's layer. It is a daemon; Gutter is a
window. It has no renderer of its own and draws inside whatever terminal you
attach with, so a plausible end state is Herdr running *inside* a Gutter tab.

The one capability it has that Gutter has no answer for is **persistence and
reattach**. The one detection trick it has that Gutter lacks is **regex over
the rendered screen**, and it pays for that with a hand-maintained per-agent
rules file that it updates over the network.

For Claude Code specifically, Gutter and Herdr read the same signal and are
level.

## What it is (from their site and README)

- Tagline: "Run them *anywhere.* Leave them running." / "the runtime your
  coding agents live on". Apache 2.0, Y Combinator-backed.
- A background server that owns agent ptys. Sessions survive a closed lid, a
  dropped network, and a machine restart; you reattach from any device with a
  keyboard.
- On top of that, a mouse-first TUI multiplexer - click panes, drag borders,
  split and switch from right-click menus. A tmux/zellij replacement, not a
  terminal emulator.
- A CLI and a local socket API that agents themselves drive: spawn panes,
  prompt each other, wait until another agent is genuinely blocked.
- Single binary. macOS, Linux, Windows. `brew install herdr`.
- Runs Claude Code, Codex, Cursor, opencode, Grok and others without wrapping
  or replacing them - it owns their terminals instead.
- A plugin system: custom executables with manifest actions and event hooks.

## How it decides an agent is working, blocked, or idle

All four mechanisms below were read in their source. Paths are relative to
their repo root at `4b5e9bd`.

### 1. Regex over the rendered screen - the primary engine

`src/detect/manifest.rs:366` (`detect_with_osc`), rule schema at `:190`.

Rules match named regions of the rendered screen, listed at `:1106-1119`:
`whole_recent`, `bottom_lines(n)`, `bottom_non_empty_lines(n)`,
`prompt_box_body`, `above_prompt_box`, `after_last_horizontal_rule`,
`after_last_prompt_marker`, `osc_title`, `osc_progress`.

Prompt markers are text heuristics (`codex_prompt_line`, `:1388`), **not** OSC
133 shell integration.

The rules live in per-agent TOML: `src/detect/manifests/*.toml`, 21 files today
(amp, antigravity, claude, cline, codex, cursor, devin, droid, gemini,
github-copilot, grok, hermes, kilo, kimi, kiro, maki, muse, opencode, pi,
qodercli, qwen). Users override them from
`~/.config/herdr/agent-detection/*.toml` (`:1129`), and Herdr refreshes them
from `https://herdr.dev/agent-detection/index.toml` over curl
(`src/detect/manifest_update.rs:16`).

Claude Code's rules: `working` is a braille or half-circle spinner in the OSC
title, or the text `esc to interrupt` in the bottom 12 lines. `blocked` is "do
you want to proceed?" plus a numbered Yes/No.

When no rule matches, the state is Idle (`manifest.rs:558-573`).

### 2. OSC title and OSC 9;4 progress

`src/pane/osc.rs:450-493`. Of every OSC the pty emits, only commands `0`, `2`
and `9` are retained. Claude, amp, codex, grok, hermes and qwen use them. Grok
keys `^4;1;-1$` to working and `^4;0;0$` to idle.

These are the two channels Gutter already reads.

### 3. The agent reports its own state over Herdr's socket

Method `pane.report_agent`, with `state: working|blocked|idle`. Six agents ship
a plugin that calls it: pi, omp, mastracode, opencode, kilo, kimi
(`src/detect/mod.rs:316-327`, `full_lifecycle_hook_authority`). When one is
active, screen detection is skipped entirely - the API reports
`"screen_detection_skip_reason": "full_lifecycle_hook_authority"`
(`src/app/api/agents.rs:279`).

This is out-of-band. A consumer that only sees terminal output cannot
replicate it.

### 4. Process inspection

`tcgetpgrp` plus `/proc/<pid>` or libproc (`src/platform/macos.rs:272,390`, and
the Linux equivalent). Used to identify *which* agent occupies a pane, and to
notice the process exited (then: Idle). Not used to infer that an agent is
working.

### opencode, specifically

Gutter's own investigation concluded opencode reports nothing usable in-band.
Herdr agrees, in code.

Its opencode manifest (`manifests/opencode.toml`) holds three weak text rules -
`esc to interrupt`, `△ Permission required`, and `(■|⬝){4,}` - and they are the
fallback, not the mechanism. Live status comes from
`src/integration/assets/opencode/herdr-agent-state.js`, an opencode plugin that
subscribes to `session.status`, `tool.execute.before/after`,
`permission.asked` (-> blocked) and `session.idle` (-> idle), and writes JSON to
`$HERDR_SOCKET_PATH`.

That is the same shape as the community `opencode-terminal-progress` plugin
that `DESIGN.md` already points at, differing only in where it sends the
result. **This confirms the existing "opencode reports nothing on its own"
analysis rather than contradicting it. No edit needed there.**

### What is not in their source

Checked for and absent, which is as informative as what is present:

- BEL as a state signal. `AppEvent::TerminalBell` is forwarded to the client
  and nothing else (`src/app/actions.rs:1778` returns `Vec::new()`).
- Inbound OSC 777, OSC 99, or OSC 1337.
- Bytes-per-second or idle-timer heuristics.
- Counting `CSI ?2026h/l` synchronized-update pairs. The pty byte counter at
  `src/pane/agent_detection.rs:319` exists only to skip redundant screen scans.
- Reading `~/.claude` or session transcripts for status. Transcript paths are
  stored for resume, not for state.

**So: beyond the OSC title and OSC 9;4, Herdr's only in-band signal is regex
over rendered text.** There is no protocol we have been missing.

## What it means for Gutter

Our reading, not their claims.

### The layers don't overlap

Herdr owns ptys and persists them. Gutter owns a window and renders one. Herdr
ships no renderer; Gutter ships no daemon. `herdr attach` typed into a Gutter
tab works today and needs no code here - Gutter stays self-contained precisely
because it never learns that herdr exists.

### One thing they ship is still declined here; the other since shipped

Session restore is still declined (`DESIGN.md`, "Not a product"). A competitor
shipping it is not an argument to reverse it; that was settled under "Not
competing with iTerm", where wanting to own the experience is the stated
motivation and "tool X already does this" is explicitly not on its own an
argument.

Splits were the other one, and they have since been built - see "Splits:
declined, then reversed". Note what did *and did not* move that decision:
herdr shipping splits was never the argument. What changed it was discovering
the cost estimate was wrong, because ghostty's own split tree and split views
were already vendored and compiling. The rule above survives intact.

### On status detection, Claude Code is a tie

Their spinner rule reads the same OSC title Gutter's does. Their
`esc to interrupt` rule is a redundant second path to a state Gutter already
has. Nothing to copy.

### The real gap is "blocked" for non-Claude agents

Gutter could technically do screen regex: libghostty exposes surface text -
it's what the accessibility path reads, and the `CachedValue` race that
`vendor.sh` patches is in exactly that code. So this is a choice, not a limit.

The cost is the part worth writing down. Herdr needs 21 hand-written rule files
and a network updater to keep them current, and their most recent commit at the
time of research was `fix: match claude bash permission prompts at every cursor
position` - a rules fix, for the agent they support best. That is the treadmill
in one line. It also runs against "Self-contained", which forbids network
access and reading another tool's config.

### Reattach is the gap with no answer, and it may not be ours to fill

Claude Code has shipped this itself (measured, `claude --help`):

| Command | Does |
| --- | --- |
| `claude --bg` | Starts detached, prints a short id |
| `claude agents` | Lists background sessions |
| `claude attach <id>` | Opens one in the current terminal |
| `claude logs <id>` | Prints recent output |
| `claude respawn --all` | Restarts them on the current version |
| `claude --resume [term]` | Interactive picker; extra text is a search term |

`LauncherConfig` takes the whole rest of the line as the command, so
`launcher = claude --resume` is a valid launcher today, and the request sheet's
prompt arrives as the picker's search term. Gutter already knows each tab's
folder from libghostty's pwd action, so "resume in the folder I'm in" is free.

Unverified: whether `--bg` sessions survive a reboot. `respawn` existing hints
they don't, but that is a guess.

## Open questions

- Does `claude --bg` survive a machine restart? One manual test answers it, and
  it decides whether Gutter needs anything beyond a launcher line.
- Should "screen-text regex for agent status" become a declined entry in
  `DESIGN.md`? It will be re-proposed otherwise, and the reasons against it are
  not visible in the code.
- "Gutter is also for agent orchestration" - does that mean managing several
  agents (already the scope, stated more plainly) or agents talking to each
  other, as Herdr's socket API does? The second is a different app.

## Sources

- https://herdr.dev/ and https://herdr.dev/docs
- https://github.com/herdrdev/herdr at `4b5e9bd`, v0.8.2
- `claude --help`, Claude Code as installed 2026-09-06
