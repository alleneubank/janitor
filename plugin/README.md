# janitor-bash-drain (Claude Code plugin)

Wraps the Claude Code `Bash` tool so that any process a session starts is
supervised by [`janitor`](https://github.com/alleneubank/janitor) and drained
when the session goes away — including a normal exit, `/clear`, a crash, or the
terminal window being closed. No per-command effort, no orphaned dev servers,
watchers, or daemons holding ports and files after the session is gone.

## What it does

A `PreToolUse` hook on the `Bash` tool transparently rewrites each command to:

```sh
janitor --watch-path '<session-lock>' --watch-pid '<claude-pid>' --grace-ms <ms> -- bash -c '<your command>'
```

- `--watch-path` is a per-session lock file; a `SessionEnd` hook removes it on a
  clean exit, which tells `janitor` to drain.
- `--watch-pid` is the Claude session process id. If the session dies hard
  (crash / `SIGKILL` / closed terminal) so no `SessionEnd` runs, `janitor` still
  sees that pid exit and drains the process group anyway. This matters because a
  Bash command runs under a per-command shell that survives the session, so
  watching the session pid directly is the only reliable crash trigger.

On teardown, `janitor` sends `SIGTERM` to the original command process group,
then drains live descendants whose identity it can prove. Processes already
reparented before capture and targets that fail identity verification are
skipped with a diagnostic, so they are outside that guarantee.

Your command's stdout/stderr, exit code, and `run_in_background` behavior are
unchanged; `janitor` is transparent.

## Requirements & install

1. Install `janitor` and make sure it is on your `PATH`:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/alleneubank/janitor/main/install.sh | sh
   ```

   (Default install location is `~/.local/bin/janitor`.)

2. Install this plugin from the Claude Code plugin marketplace:

   ```sh
   /plugin marketplace add alleneubank/janitor
   /plugin install janitor-bash-drain@janitor
   ```

The hooks **fail open**: if `janitor` is not installed or not on `PATH`, the
hook is a no-op and your command runs unmodified. Nothing this plugin does can
block or corrupt a Bash command.

## Configuration

Configure via environment variables (read by `janitor cc-hook`). Set them in
your shell profile or project environment.

| Variable | Default | Meaning |
| --- | --- | --- |
| `JANITOR_CC_ENABLED` | `1` | Set `0`/`false` to disable wrapping entirely. |
| `JANITOR_CC_GRACE_MS` | `1500` | `SIGTERM`→`SIGKILL` grace window (ms). |
| `JANITOR_CC_WRAP_MODE` | `all` | `all` wraps every command; `background-only` wraps only `run_in_background` commands. |
| `JANITOR_CC_SHELL` | `bash` | Shell used for `-c` to re-run your command. |
| `JANITOR_CC_SKIP_PATTERNS` | read-only/trivial set | Comma-separated command prefixes to skip. Default skips `ls`, `cat`, `pwd`, `echo`, `which`, `cd`, `git status`, `git log`, `git diff`, `git show`. |
| `JANITOR_CC_DENY_PATTERNS` | _(empty)_ | Comma-separated command prefixes to never wrap. |

Read-only/trivial commands and commands that already start with `janitor` are
never wrapped (no double-wrapping, no overhead where it isn't needed).

## Platform

macOS and Linux only. On Windows — and whenever `janitor` is absent — the hook
is a no-op and commands run unmodified.
