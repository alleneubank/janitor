# Design: Claude Code plugin to drain session-spawned processes (issue #1)

Status: proposed design. Implements no code yet. Resolves the open questions in
[issue #1](https://github.com/alleneubank/janitor/issues/1) and proposes a build plan.

## Goal

Ship a Claude Code plugin so that any process a session's `Bash` tool starts is
supervised by `janitor` and drained when the session goes away — including
crash / `/clear` / terminal-close — with zero per-command effort from the user
and zero orphans within the configured grace window.

## What is fixed vs. assumed

Two facts are verified against this repo's source; everything about the Claude
Code API is from docs research and carries a confidence tag. The two
lower-confidence facts are load-bearing, so the plan front-loads a spike to
prove them before any real implementation.

### Verified from `src/root.zig`

- **F1 — janitor execs an argv after `--`, never a shell string.** `parseArgs`
  takes `command = args[i+1..]` and `run` spawns it directly
  (`std.process.Child.init(config.command, …)`, `root.zig:103-108`). A Bash
  command containing `&&`, `|`, `;`, `$(...)` etc. is *not* a single argv —
  wrapping `janitor -- <command>` verbatim would run only the first word and
  drop the rest. **The wrapper must re-inject a shell:** `janitor … -- bash -c
  '<original>'`.
- **F2 — `--watch-path` must exist at startup or janitor tears down at once.**
  `addPath` returns `FileNotFound` → `pending.put(.path_missing)`
  (`root.zig:312-317, 373-374, 446-451, 500-501`), and the first `wait` returns
  that pending event → immediate teardown. **The session lock must be created
  before any wrapped command spawns**, otherwise every command is killed
  instantly.
- **F3 — janitor watches parent, child, signals, and path simultaneously; any
  one triggers teardown** (`root.zig:122-138`). We get defense-in-depth for free
  by supplying more than one trigger.
- **F4 — parent death = `getppid() != original_parent`, captured once at start**
  (`root.zig:101, 118`; SPEC invariant). It does *not* watch an arbitrary
  ancestor — only the immediate parent at spawn time.
- **F5 — janitor is transparent.** It inherits stdio (`root.zig:105-107`) and
  propagates the child's exit status, encoding signal deaths as `128+signal`
  (`root.zig:191-198`). So Claude's stdout/stderr capture, `BashOutput`, and
  exit codes keep working through the wrapper.
- **F6 — default grace is 1500 ms** (`root.zig:10`); configurable via
  `--grace-ms`.

### Verified by spike (2026-06-03, Claude Code 2.1.162, macOS)

The two load-bearing unknowns were proven empirically; see "Spike results"
below. Field names here are observed, not guessed.

- **A1 (VERIFIED) — PreToolUse input** is JSON on stdin with exactly these keys:
  `session_id`, `transcript_path`
  (`~/.claude/projects/<slug>/<session_id>.jsonl`), `cwd`, `permission_mode`,
  `effort.level`, `hook_event_name`, `tool_name`, `tool_use_id`, and
  `tool_input`. For Bash, `tool_input` = `{command, description}` and, for
  background commands, **`run_in_background: true` is present** (so `wrapMode:
  background-only` keys off `tool_input.run_in_background == true`). There is a
  stable `session_id`; there is **no** per-session directory handed to the hook.
- **A2 (VERIFIED) — PreToolUse rewrites the command.** Printing
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"…"}}}`
  on stdout and exiting 0 causes Claude to run the modified command (confirmed:
  rewritten sentinel appeared in captured tool output and a marker file the
  rewrite created was present). The approach is feasible.
- **A3 (high) — SessionEnd is unreliable for critical cleanup.** It does not run
  on hard `SIGKILL`, may be cut off mid-run, and async work in it can be killed.
  **Conclusion: SessionEnd is only a best-effort fast path; correctness cannot
  depend on it.**
- **A4 (VERIFIED, with a sharper result than expected) — process model.**
  `run_in_background: true` commands are **NOT detached** — they stay
  descendants of the live `claude` process. BUT every Bash command (foreground
  or background) runs under its **own per-command shell in its own process
  group**, distinct from `claude`'s group. Ancestry observed:
  `sleep` → `zsh (per-command)` → `claude` for background;
  `zsh (per-command)` → `claude` for foreground. Implications in
  "Death-trigger analysis" — this is why `--watch-pid` is **required**, not
  optional.
- **A5 (high) — plugin hooks** are registered via `.claude-plugin/plugin.json`
  pointing at `hooks/hooks.json`, matcher on tool name (`"Bash"`),
  `${CLAUDE_PLUGIN_ROOT}` resolves bundled files, `${CLAUDE_PLUGIN_DATA}` is a
  writable per-plugin dir.

## Death-trigger analysis (the core of the design)

`Pp` = parent-PID (F4), `Wp` = watch-path lock, `Wpid` = watch the Claude PID.
The A4 spike pins down janitor's immediate parent: the **per-command shell**,
which sits between janitor and `claude` and is in a **different process group**.

| Scenario | Clean exit / `/exit` | Crash / `SIGKILL` / window close |
|---|---|---|
| Foreground cmd | SessionEnd deletes lock → `Wp` | per-command shell survives reparenting (blocked in `wait`); different pgroup so terminal `SIGHUP` misses it; SessionEnd does not run → only **`Wpid`** drains it |
| Background cmd | SessionEnd → `Wp`; Claude kills its bg shell | same as above → only **`Wpid`** drains it |

The crash column is the heart of the problem, and the spike shows it is **worse
than the issue assumed**:

- janitor's immediate parent is the per-command shell, **not** `claude`. When
  `claude` dies, that shell is reparented to launchd but **stays alive** (it is
  blocked waiting on its child), so `getppid()` is unchanged → **`Pp` does not
  fire**.
- The per-command shell is in its own process group, so a terminal-close
  `SIGHUP` delivered to `claude`'s group never reaches it.
- On `SIGKILL`/crash, SessionEnd does not run, so the lock is never deleted →
  **`Wp` does not fire**.

So the only trigger that reliably survives `claude`'s death is **watching the
`claude` PID directly**. Therefore:

- **`--watch-path` lock** = clean-exit fast path (SessionEnd deletes it) and a
  secondary safety net.
- **`--watch-pid <claude_pid>` = REQUIRED.** This is a small, additive janitor
  change that reuses the existing process-death machinery (kqueue
  `EVFILT_PROC`/`NOTE_EXIT`, Linux `pidfd`) — the same path already used to
  watch the parent and child PIDs (`root.zig:300-307, 424-440`).
- **parent-PID** stays enabled as a bonus (it may fire if a shell tail-call-
  `exec`s janitor, making it a direct child of `claude`), but the design does
  **not** rely on it.

The `claude` PID is trivially discoverable from the hook: walk up the ancestry
from the hook's `getppid()`, skipping shell processes, until `comm == "claude"`
(observed directly in the spike). Cache it in the lock for the session.

## Proposed architecture

Keep the plugin thin; put all parsing/decision/escaping logic where it is
testable and dependency-free.

```
plugin/                              # the distributable Claude Code plugin
  .claude-plugin/plugin.json         # name, version, hooks -> hooks/hooks.json, config schema
  hooks/hooks.json                   # PreToolUse(Bash) + SessionEnd(+SessionStart) -> janitor cc-hook ...
  README.md
janitor (binary)                     # gains a `cc-hook` subcommand (see below)
```

### Why a `janitor cc-hook` subcommand instead of a shell/jq/node script

The hook must parse JSON, decide, safely shell-escape the original command, and
manage the lock. Doing that in a POSIX-sh+`jq` script adds a runtime dependency
that may be absent and is easy to get wrong on escaping; a Node script assumes
`node` on PATH, which is not guaranteed under Claude Code's native-binary
distribution. `janitor` is **already required** for the feature to work, so
folding the hook logic into the binary it already needs gives:

- zero extra runtime deps (only `janitor`, plus a shell to exec it),
- robust JSON + shell-escaping in Zig,
- the decision logic as **pure functions** unit-tested in Zig, and the wired
  binary exercised by e2e (matches `CLAUDE.md`: keep side effects at the
  supervision boundary; no test-only behavior in `root.zig`).

`hooks/hooks.json` then just execs the binary, e.g. PreToolUse:
`{"type":"command","command":"janitor","args":["cc-hook","pretooluse"]}` and
SessionEnd `["cc-hook","session-end"]`. (Exact path resolution: prefer
`${CLAUDE_PLUGIN_ROOT}`-bundled binary if shipped with the plugin, else `janitor`
on PATH.)

Lighter alternative if the maintainer prefers no janitor scope growth: ship the
same logic as a Node script in `hooks/` and document `node` as a requirement.
The cc-hook approach is recommended.

### `cc-hook pretooluse` behavior (per invocation)

Reads PreToolUse JSON on stdin; writes either nothing (proceed unmodified) or an
`updatedInput` JSON; **always exits 0 and fails open** — any error → emit
nothing → original command runs untouched. Never block or corrupt a command.

1. **Platform guard.** Non-macOS/Linux → passthrough (Windows no-op, per issue).
2. **Resolve config** (see Config) — if disabled → passthrough.
3. **Locate janitor.** Not found on PATH/plugin root → passthrough.
4. **Skip checks → passthrough if any:**
   - command already wrapped (first token after optional leading
     `VAR=val`/whitespace is `janitor` or the janitor path) — avoids double-wrap;
   - command matches a `skipPatterns` regex (default set of read-only/trivial
     commands: `ls`, `cat`, `pwd`, `echo`, `which`, `git status|log|diff|show`,
     `cd`, etc.);
   - `wrapMode == "background-only"` and `tool_input.run_in_background` is not
     true.
5. **Ensure the session lock exists** (F2). Lock path is derived deterministically
   from `session_id`:
   `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/janitor-cc/<session_id>.lock`.
   Create parent dir + file if missing. Lock file content = the resolved Claude
   session PID (see PID resolution), written once and reused.
6. **Build the wrapped command** and emit
   `updatedInput.command = `:
   ```
   janitor --watch-path <lock> --watch-pid <claude_pid> --grace-ms <g> -- <shell> -c '<orig>'
   ```
   - `<shell>` defaults to `bash` (`sh` fallback if bash absent), configurable;
     `bash -c` (non-login) to minimize env divergence from Claude's own shell.
   - `<orig>` is single-quote-escaped (`'` → `'\''`) so the entire original
     command, operators included (F1), is one argv element re-parsed by the
     inner shell.
   - `--watch-pid <claude_pid>` is always included when PID resolution succeeds
     (A4 proved it is the only reliable crash trigger); omitted only if
     resolution is unconvincing, degrading to lock + parent-PID.

`run_in_background` is preserved as-is on the rewritten command — the wrapper is
a transparent prefix (F5), so Claude's background handling and `BashOutput`
still work; janitor supervises in the foreground of that background shell.

### `cc-hook session-end` behavior

Delete the session lock derived from `session_id`. Best-effort, fail open. This
is the fast, clean-exit teardown path; the crash path is covered by
`Pp`/`Wpid`, not by this hook (A3).

### `cc-hook` also prunes stale locks

On `session-start` (or lazily on first `pretooluse`), remove lock files whose
recorded PID is dead, so crashes don't leak lock files indefinitely. The leaked
file is harmless (the janitor instances watching it already drained via
`Wpid`), but pruning keeps the runtime dir clean.

### Claude session PID resolution (for `--watch-pid`)

The hook is a descendant of the Claude process. Resolution: start at the hook's
own `getppid()`; if that process's `comm` is a known shell (`sh`/`bash`/`zsh`),
walk up one hop (cap ~3 hops) to skip an ephemeral `sh -c` wrapper; use the
result. Cache it in the lock file so the walk happens once per session. If
resolution is unconvincing, **omit `--watch-pid`** and fall back to lock +
parent-PID (graceful degradation — never wire janitor to a wrong PID, which
could cause premature teardown). The spike validates the resolved PID by hard-
killing Claude and asserting drain.

### Config knobs (issue requirement)

Resolved in order (later overrides earlier): plugin defaults →
`${CLAUDE_PROJECT_DIR}/.claude/janitor-plugin.json` → `JANITOR_CC_*` env. Keys:

- `enabled` (bool, default true)
- `graceMs` (int, default 1500 — janitor's default)
- `wrapMode` (`"all"` | `"background-only"`, default `"all"`)
- `shell` (default `"bash"`)
- `skipPatterns` (regex list; default covers common read-only/trivial commands)
- `denyPatterns` (regex list; never wrap, e.g. interactive REPLs if desired)

## Proposed SPEC additions (REQ IDs for traceability)

- **REQ-PLUGIN-001**: A Claude Code plugin registers a PreToolUse(Bash) hook that
  rewrites the command to run under `janitor`, requiring no per-command user
  action.
- **REQ-PLUGIN-002**: The hook re-injects a shell (`<shell> -c '<orig>'`) so
  shell operators in the original command are preserved (F1).
- **REQ-PLUGIN-003**: A per-session lock file (keyed by `session_id`) exists
  before any wrapped command runs (F2) and is passed via `--watch-path`.
- **REQ-PLUGIN-004**: SessionEnd deletes the lock as a best-effort clean-exit
  teardown; correctness does not depend on it firing (A3).
- **REQ-PLUGIN-005**: The hook fails open — on any error, unsupported platform,
  or missing `janitor`, the original command runs unmodified.
- **REQ-PLUGIN-006**: The hook does not double-wrap an already-`janitor` command
  and skips configured read-only/trivial patterns.
- **REQ-JANITOR-013 (required, per A4)**: janitor accepts `--watch-pid PID` and
  tears down the child process group when that PID exits, watched via the same
  event backend as the parent/child PIDs (kqueue `EVFILT_PROC` / Linux `pidfd`).
- **REQ-PLUGIN-007**: the plugin resolves the `claude` session PID (ancestry
  walk, `comm == "claude"`) and passes it via `--watch-pid` so processes drain
  on hard session kill, where neither parent-PID nor SessionEnd is reliable
  (A4).

## Acceptance tests (map to issue acceptance criteria)

- **AC1 "no per-command changes":** unit — feed sample PreToolUse JSON to
  `cc-hook pretooluse`; assert stdout `updatedInput.command` equals
  `janitor --watch-path <lock> [--watch-pid N] --grace-ms 1500 -- bash -c '<escaped orig>'`.
  Cases: plain command, command with `&&`/pipe/quotes (escaping), already-wrapped
  (passthrough), skip-pattern (passthrough), `run_in_background` preserved.
- **AC2 "zero orphans within grace":** e2e (extend `src/e2e.zig` harness) —
  - clean-exit path: create lock, `janitor --watch-path lock -- bash -c '<TERM-ignoring tree>'`,
    delete lock, assert tree drained;
  - crash path (contingency): `janitor --watch-pid <pid> --watch-path lock -- bash -c '<tree>'`,
    kill `<pid>`, assert tree drained even with lock still present.
- **AC3 "trivial commands excluded":** unit — `decide()` returns skip for the
  default read-only set and wrap otherwise; fail-open on malformed JSON.

## Spike results (2026-06-03 — DONE)

- **A2 PASS.** Headless `claude -p` with a PreToolUse(Bash) hook returning
  `hookSpecificOutput.updatedInput.command` ran the rewritten command (sentinel
  in tool output + marker file created). Exact input schema captured (see A1).
- **A4 PASS, sharper than expected.** Background commands are not detached but
  run under a per-command shell in a separate process group; that shell survives
  `claude`'s death. ⇒ `--watch-pid <claude_pid>` is required, not optional. The
  `claude` PID is reachable by an ancestry walk (`comm == "claude"`).

## Plan (phased — spike complete)

1. **janitor `--watch-pid PID`** in `root.zig` (REQ-JANITOR-013): add a third
   proc watch alongside parent/child in both `KqueueWatcher` and `LinuxWatcher`,
   parse the flag in `parseArgs`, map its `NOTE_EXIT`/`pidfd` event to a new
   teardown reason. SPEC + e2e (AC2 crash path, extends `src/e2e.zig`).
2. **janitor `cc-hook` subcommand** in a new `src/cc_hook.zig`: pure
   `parse`/`decide`/`escape`/`resolveClaudePid`/`buildCommand` functions + thin
   IO in `main.zig` dispatch (`cc-hook pretooluse` / `cc-hook session-end`).
   Unit tests (AC1, AC3). No change to `root.zig` beyond step 1.
3. **Plugin package** (`plugin/`): `.claude-plugin/plugin.json`,
   `hooks/hooks.json` (PreToolUse(Bash) + SessionEnd), README, config schema.
   Manual install test, then marketplace metadata.
4. **Docs + SPEC**: new "Claude Code plugin" section in repo README; `SPEC.md`
   REQ additions (REQ-JANITOR-013, REQ-PLUGIN-001..007) with traceability rows.

High-risk per `CLAUDE.md` ADF: adds a public plugin surface and a CLI flag, so
PLAN approval is expected before DEV.

## Alternatives if A2 fails (PreToolUse cannot rewrite the command) — NOT NEEDED

A2 passed in the spike, so these are recorded only as fallback context:

- Configure Claude Code's Bash tool to use a wrapper shell that prepends janitor
  (if such a hook/setting exists) — coarser, no per-command skip.
- Provide a `janitor`-aware shell function/alias and document manual opt-in —
  this is the status quo the issue wants to remove; only a fallback.

## Out of scope

- Windows (janitor non-goal; hook passes through).
- Children that `setsid()` away from the wrapped shell's group (janitor's
  documented limitation; would need their own nested janitor).
- A persistent daemon/registry (janitor non-goal).
