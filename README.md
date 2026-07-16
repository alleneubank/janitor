# janitor

`janitor` runs a command in its own process group and drains its live process
descendants when its owner goes away.

It is meant for development stacks where one layer can die without running a
clean shutdown: shells, Claude Code sessions, zmx, Tilt, `serve_cmd`, local
chains, indexers, dev servers, and similar long-running commands.

## Why

Process trees often outlive the thing that started them. If the parent shell,
terminal session, editor agent, or Tilt process exits unexpectedly, child
services can be reparented to `launchd`, `systemd`, or another subreaper and
keep ports, files, databases, and CPU alive.

`janitor` makes that ownership explicit:

1. Capture the original parent PID.
2. Spawn the command as a new process-group leader.
3. Watch the parent, child, signals, and optional worktree path.
4. On any death trigger, snapshot the direct child's live PPID-linked descendant
   closure before sending any teardown signal.
5. Send `SIGTERM` to the original child process group and to identity-verified
   descendants that escaped it.
6. Wait for the grace window, then send `SIGKILL` if anything in the full drain
   set remains.

## Install

The installer defaults to the latest stable GitHub Release and selects the
archive for the current platform.

```sh
curl -fsSL https://raw.githubusercontent.com/alleneubank/janitor/main/install.sh | sh
```

By default this installs to `~/.local/bin/janitor`. Override with `PREFIX`:

```sh
curl -fsSL https://raw.githubusercontent.com/alleneubank/janitor/main/install.sh | PREFIX=/usr/local sh
```

Install a specific release tag:

```sh
curl -fsSL https://raw.githubusercontent.com/alleneubank/janitor/main/install.sh | JANITOR_VERSION=v0.1.0 sh
```

Source installation remains available for unsupported platforms and maintainer
testing. It requires Zig `0.15.2` or newer:

```sh
JANITOR_INSTALL_FROM_SOURCE=1 ./install.sh
```

## Usage

```sh
janitor [--watch-path PATH] [--watch-pid PID] [--grace-ms MS] [--poll-ms MS] [--pgroup-only] -- CMD [ARGS...]
janitor version | --version | -V
```

`janitor version` (or `--version` / `-V`) prints `janitor <version> (<sha>)`,
where `<sha>` is the short git commit the binary was built from (`unknown` when
built outside a git checkout), so a deployed binary can be matched to its source.

Examples:

```sh
janitor --watch-path "$PWD" -- yarn localnet:up
janitor --watch-path "$PWD" -- bun run src/index.ts daemon
janitor --grace-ms 500 -- tilt up
```

`--watch-path` is useful for worktree-based development. If the worktree is
deleted or moved, `janitor` treats that as a teardown trigger.

`--watch-pid` watches an arbitrary process by PID. When that process exits,
`janitor` treats it as a teardown trigger. This is useful when the supervised
command is reparented away from `janitor`, so watching the owning process
directly is more reliable than relying on `janitor`'s immediate parent.

`--poll-ms` is accepted for compatibility with earlier development builds. On
supported platforms, the active watcher is event-driven and does not use
periodic idle polling.

By default, teardown takes a live descendant snapshot before its first TERM.
The original child process group remains the fast path and the only process
group signaled wholesale. A descendant that called `setsid()` or otherwise
escaped that group is signaled individually only when Janitor can revalidate
the captured process identity; this prevents PID reuse from targeting an
unrelated process. `--pgroup-only` is the escape hatch for the prior
process-group-only behavior.

## Platform Behavior

- macOS and BSD use `kqueue` for process, signal, vnode, and timeout waits.
- Linux uses `epoll` over `pidfd`, `signalfd`, and `inotify`.
- Process watches, including the original parent, child, and any `--watch-pid`
  target, use `EVFILT_PROC` / `NOTE_EXIT` on macOS/BSD and `pidfd` on Linux.
- Windows is not supported.

The child command is started in a new process group. Teardown signals that
original group wholesale, then handles proven escaped descendants individually;
it never signals every process group represented by a snapshot. Linux uses
pidfds for stable individual-process identity. macOS/BSD use the strongest
available start identity and immediate revalidation, with support claims limited
to what the native platform verification enforces. If discovery is incomplete,
Janitor diagnoses it, still drains the original group, and never guesses at
additional signal targets.

## Claude Code plugin

The bundled Claude Code plugin wraps the `Bash` tool so processes a session
starts are drained by `janitor` when the session ends, including crashes,
`/clear`, and closed terminals.

It registers a `PreToolUse(Bash)` hook (`janitor cc-hook pretooluse`) that
rewrites commands to run under `janitor`, tied to the session by a per-session
lock (`--watch-path`) and the Claude session PID (`--watch-pid`). A `SessionEnd`
hook drops the lock on clean exits.

The hook fails open: if `janitor` is missing, unsupported, or errors, commands
run unmodified. The plugin supports macOS and Linux only.

Install from the Claude Code plugin marketplace:

```sh
/plugin marketplace add alleneubank/janitor
/plugin install janitor-bash-drain@janitor
```

See `plugin/` and `plugin/README.md` for install details and the `JANITOR_CC_*`
configuration knobs.

## Limitations

- A descendant already reparented before the teardown snapshot is not
  recoverable through PPID ancestry and remains out of scope. Janitor is not a
  lifetime owner: it does not continuously track forks or use cgroups or a
  persistent process registry.
- A live `setsid()` descendant is drained by default only when its PPID ancestry
  and identity can be proven. If either cannot be verified, Janitor skips and
  diagnoses that individual target rather than risk signaling an unrelated
  process; `--pgroup-only` intentionally omits all escaped descendants.
- `SIGKILL` sent directly to `janitor` cannot be handled by any userspace
  wrapper, so cleanup is impossible in that one case.
- The exit status follows the direct child when available. Signal deaths are
  encoded as `128 + signal`.

## Build And Test

```sh
zig build
zig build run -- --help
zig build test
zig build fmt
zig build docs
```

`zig build test` includes end-to-end checks that launch real process trees and
verify watched-path, signal, and parent-death cleanup.

Linux can be typechecked from macOS with:

```sh
zig build -Dtarget=x86_64-linux
```

## Release Notes For Maintainers

Janitor's release archives target hash-verifying CLI installers and package
managers such as the bundled installer, mise, and Nix. macOS binaries carry a
credential-free ad-hoc signature: it proves the binary did not change after
signing, but it does not assert an Apple-verified developer identity. Browser or
Finder distribution of quarantined downloads is not part of this release
contract.

Build and verify a macOS archive locally:

```sh
scripts/release-macos.sh
```

Use `scripts/release-macos.sh --dry-run --target aarch64-macos` to inspect the
build, ad-hoc signing, packaging, extraction, and strict verification commands.
No Apple certificate, keychain profile, password, private key, or notarization
credential is required.

Version tags create a draft GitHub Release with prebuilt Linux and macOS
archives plus checksum files. GitHub Actions uses the same local release script
for macOS and attaches an archive only after its extracted binary passes
`codesign --verify --strict`.

Release bumps must update `plugin/.claude-plugin/plugin.json` to match
`build.zig.zon`; `zig build check-plugin-version` enforces the two versions
stay in sync.
