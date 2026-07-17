# janitor

`janitor` runs a command in its own process group and tears that group down when
its owner goes away.

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
4. On any death trigger, snapshot the direct child's live PPID descendants.
5. Send `SIGTERM` to the child process group and individually to verified
   descendants that escaped it.
6. Wait for the grace window, then send `SIGKILL` if anything remains.

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

By default, teardown snapshots the direct child's live PPID-linked descendants
before sending `SIGTERM`. Janitor keeps its original process-group fast path,
and only individually signals an escaped descendant after platform identity
verification proves it is the captured process. Use `--pgroup-only` to opt out
and retain the historical behavior that drains only the original child process
group.

## Platform Behavior

- macOS and BSD use `kqueue` for process, signal, vnode, and timeout waits.
- Linux uses `epoll` over `pidfd`, `signalfd`, and `inotify`.
- Process watches, including the original parent, child, and any `--watch-pid`
  target, use `EVFILT_PROC` / `NOTE_EXIT` on macOS/BSD and `pidfd` on Linux.
- Windows is not supported.

Snapshot descendant draining is supported on Linux and macOS. Other BSD
platforms retain the original process-group-only teardown: Janitor reports that
the descendant snapshot is unavailable and never guesses individual targets.
Those BSD backends cannot observe a child exit without reaping its group
leader. Once that happens Janitor stops issuing numeric process-group signals,
because a recycled PGID could otherwise target an unrelated group; this
deliberately favors signal safety over any remaining group cleanup breadth.

The child command is started in a new process group. Janitor signals only that
group wholesale; escaped descendants are individually addressed through their
captured identity. Unsupported descendant-discovery backends, including BSD
platforms other than macOS, diagnose the limitation and retain group-only
teardown rather than guessing at targets.

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

- Snapshot ownership covers only descendants still PPID-linked to the direct
  child before teardown begins. A process already reparented before that point
  is outside the recovery guarantee.
- Use `--pgroup-only` when a deliberately self-daemonizing child must remain
  outside Janitor's teardown scope.
- `SIGKILL` sent directly to `janitor` cannot be handled by any userspace
  wrapper, so cleanup is impossible in that one case.
- The exit status follows the direct child when available. Signal deaths are
  encoded as `128 + signal`.
- On FreeBSD, OpenBSD, NetBSD, and DragonFly, a child exit observed during a
  teardown may leave remaining original-group members undrained: Janitor has
  already reaped the leader and will not risk signaling a recycled PGID.

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

The FreeBSD and NetBSD group-only backends are compile-verified with
`-Dtarget=x86_64-freebsd` and `-Dtarget=x86_64-netbsd`. Their native process
semantics are not part of this Linux e2e suite; snapshot descendant draining is
advertised and native-tested only on Linux and macOS.

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
