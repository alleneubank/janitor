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

## Install From Source

Requires Zig `0.15.2` or newer.

From a checkout:

```sh
./install.sh
```

From GitHub after the repo is published:

```sh
curl -fsSL https://raw.githubusercontent.com/alleneubank/janitor/main/install.sh | sh
```

By default this installs to `~/.local/bin/janitor`. Override with `PREFIX`:

```sh
PREFIX=/usr/local ./install.sh
```

If testing before the public remote is renamed, point the installer at any clone
URL:

```sh
JANITOR_REPO_URL=https://github.com/alleneubank/janitor.git sh install.sh
```

## Usage

```sh
janitor [--watch-path PATH] [--grace-ms MS] [--poll-ms MS] -- CMD [ARGS...]
```

Examples:

```sh
janitor --watch-path "$PWD" -- yarn localnet:up
janitor --watch-path "$PWD" -- bun run src/index.ts daemon
janitor --grace-ms 500 -- tilt up
```

`--watch-path` is useful for worktree-based development. If the worktree is
deleted or moved, `janitor` treats that as a teardown trigger.

`--poll-ms` is accepted for compatibility with earlier development builds. On
supported platforms, the active watcher is event-driven and does not use
periodic idle polling.

## Platform Behavior

- macOS and BSD use `kqueue` for process, signal, vnode, and timeout waits.
- Linux uses `epoll` over `pidfd`, `signalfd`, and `inotify`.
- Windows is not supported.

The child command is started in a new process group. Teardown only signals that
group, so unrelated processes are not touched.

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

For macOS distribution outside the App Store, release binaries should be signed
with a Developer ID Application certificate and submitted to Apple's notary
service. This repository intentionally does not store signing credentials.

Create a local notarytool keychain profile once. Enter the app-specific password
only through Apple's secure prompt; do not pass it as a command argument:

```sh
xcrun notarytool store-credentials janitor-notary \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id H93YRR23HH
```

Build the signed and notarized macOS archive locally:

```sh
scripts/release-macos.sh
```

Use `scripts/release-macos.sh --dry-run --skip-sign --skip-notarize` to inspect
the release commands without requiring signing credentials.

The script checks `codesign` locally and waits for Apple notarization to return
`Accepted`. Raw CLI zip archives are not stapled like app bundles or packages,
so Gatekeeper checks the notarization ticket online after download.

Version tags create a draft GitHub Release with unsigned Linux archives and
checksum files. Attach the signed and notarized macOS zip from `dist/` before
publishing the release. Homebrew can come later once archive URLs and checksums
are stable.
