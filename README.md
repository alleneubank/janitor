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
4. On any death trigger, send `SIGTERM` to the child process group.
5. Wait for the grace window, then send `SIGKILL` if anything remains.

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
janitor [--watch-path PATH] [--watch-pid PID] [--grace-ms MS] [--poll-ms MS] -- CMD [ARGS...]
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

## Platform Behavior

- macOS and BSD use `kqueue` for process, signal, vnode, and timeout waits.
- Linux uses `epoll` over `pidfd`, `signalfd`, and `inotify`.
- Process watches, including the original parent, child, and any `--watch-pid`
  target, use `EVFILT_PROC` / `NOTE_EXIT` on macOS/BSD and `pidfd` on Linux.
- Windows is not supported.

The child command is started in a new process group. Teardown only signals that
group, so unrelated processes are not touched.

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

- A descendant that deliberately calls `setsid()` or moves to another process
  group can escape. Wrap that daemon with its own `janitor` if it self-daemonizes.
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

For macOS distribution outside the App Store, release binaries are signed with a
Developer ID Application certificate and submitted to Apple's notary service.
This repository intentionally keeps signing credentials in GitHub Secrets or the
local macOS keychain, never in tracked files.

Create a local notarytool keychain profile once. Enter the app-specific password
only through Apple's secure prompt; do not pass it as a command argument:

```sh
xcrun notarytool store-credentials janitor-notary \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id H93YRR23HH
```

Build a signed and notarized macOS archive locally:

```sh
scripts/release-macos.sh
```

Use `scripts/release-macos.sh --dry-run --skip-sign --skip-notarize` to inspect
the release commands without requiring signing credentials.

The script checks `codesign` locally and waits for Apple notarization to return
`Accepted`. Raw CLI zip archives are not stapled like app bundles or packages,
so Gatekeeper checks the notarization ticket online after download.

Version tags create a draft GitHub Release with prebuilt Linux and macOS
archives plus checksum files. The macOS archives are signed and notarized in
GitHub Actions when the required Apple signing secrets are present. Homebrew can
come later once archive URLs and checksums are stable.

Release bumps must update `plugin/.claude-plugin/plugin.json` to match
`build.zig.zon`; `zig build check-plugin-version` enforces the two versions
stay in sync.
