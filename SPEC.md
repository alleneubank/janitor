# janitor SPEC

`janitor` exists to stop development processes from surviving after their owner
has gone away. This happens in layered tools such as Claude Code, zmx, shells,
Tilt, and `serve_cmd` resources: one layer can die without running a graceful
teardown, while child processes keep running under `launchd` or another
subreaper.

The solution is a small wrapper. It starts the target command in a new process
group, watches for owner-death signals, and drains that group with
`SIGTERM -> grace -> SIGKILL`.

## Domain Model

- **Janitor**: the `janitor` process.
- **Original parent**: `janitor`'s parent PID captured before spawning the child.
- **Child process group**: the process group created for the target command.
- **Controlling terminal**: the terminal `janitor` inherits on standard input
  when launched interactively; its foreground process group governs keyboard
  input and terminal-generated signal (`Ctrl-C`/`SIGINT`) delivery.
- **Death trigger**: parent PID change, watched-path disappearance,
  watched-PID exit, or `TERM`/`INT`/`HUP` delivered to `janitor`.
- **Grace window**: bounded delay after `SIGTERM` before `SIGKILL`.
- **Release artifact**: a versioned archive containing the `janitor` binary,
  README, LICENSE, and checksum material for GitHub Releases.
- **Ad-hoc signature**: a credential-free Mach-O code signature that detects
  post-signing byte changes without asserting an Apple-verified developer
  identity.
- **Package-manager distribution**: installation through a hash-verifying CLI
  such as Nix or mise, which does not model browser-downloaded, quarantined app
  distribution.
- **Stable release**: the latest non-draft, non-prerelease GitHub Release
  selected by GitHub's `releases/latest` endpoint.
- **Build metadata**: the package version (from `build.zig.zon`) and the short
  git commit the binary was built from, injected at build time and surfaced by
  the version command so a deployed binary can be matched to its source.

## Requirements

- **REQ-JANITOR-001**: The CLI accepts
  `--watch-path PATH`, `--watch-pid PID`, `--grace-ms MS`, `--poll-ms MS`, and
  requires `--` before the command.
- **REQ-JANITOR-002**: The child command runs in a new process group whose PGID
  is the child PID.
- **REQ-JANITOR-003**: If the original parent PID changes, `janitor` tears down
  the child process group.
- **REQ-JANITOR-004**: If the watched path is missing, `janitor` tears down the
  child process group.
- **REQ-JANITOR-005**: `TERM`, `INT`, and `HUP` delivered to `janitor` request
  the same process-group teardown.
- **REQ-JANITOR-006**: Teardown sends `SIGTERM` to the child process group,
  waits through the grace window, and sends `SIGKILL` if any group member still
  exists.
- **REQ-JANITOR-007**: The grace check observes process-group liveness, not only
  the direct child PID.
- **REQ-JANITOR-008**: If the direct child exits by itself while descendants are
  still in the child process group, `janitor` drains the remaining group before
  exiting.
- **REQ-JANITOR-009**: `janitor` exits with the direct child's status when the
  child status is available, encoding signal deaths as `128 + signal`.
- **REQ-JANITOR-010**: On macOS/BSD, parent exit, child exit, watched-path
  deletion, watched-PID exit, and shutdown signals are watched through `kqueue`.
- **REQ-JANITOR-011**: On Linux, parent exit, child exit, watched-path deletion,
  watched-PID exit, and shutdown signals are watched through `epoll` over
  `pidfd`, `signalfd`, and `inotify`.
- **REQ-JANITOR-012**: Supported event backends do not wake periodically while
  idle; timeout waits are used only for the configured teardown grace window.
- **REQ-JANITOR-013**: When `janitor`'s standard input is a terminal, `janitor`
  transfers terminal foreground ownership (`tcsetpgrp`) to the child process
  group after the child is spawned, so an interactive child receives keyboard
  input and terminal-generated signals (`Ctrl-C`) directly rather than through
  `janitor`'s grace-windowed teardown; `janitor` restores the previously
  foreground process group before it exits. When standard input is not a
  terminal, `janitor` leaves terminal state untouched.
- **REQ-JANITOR-014**: If the `--watch-pid` PID exits, `janitor` tears down the
  child process group.
- **REQ-JANITOR-015**: `janitor --version`, `janitor -V`, and the `janitor
  version` subcommand print the package version and the build-time short git
  commit (`janitor <version> (<sha>)`) to standard output and exit 0. The
  version is single-sourced from `build.zig.zon`; the commit degrades to
  `unknown` when built outside a git checkout.
- **REQ-JANITOR-016**: The Claude Code plugin manifest version in
  `plugin/.claude-plugin/plugin.json` equals the package version in
  `build.zig.zon`; `zig build check-plugin-version` enforces the two versions
  stay in sync.
- **REQ-RELEASE-001**: The repository provides a local macOS release script that
  builds `ReleaseSafe`, applies a credential-free ad-hoc signature, packages
  README and LICENSE beside the binary, extracts the archive, and verifies the
  extracted binary with strict code-signature validation.
- **REQ-RELEASE-002**: Release automation requires no Apple signing identity,
  certificate, password, private key, notarization credential, or other secret.
- **REQ-RELEASE-003**: The macOS release script supports a dry-run mode so
  maintainers can validate the exact build, signing, packaging, extraction, and
  verification commands without credentials or filesystem mutation.
- **REQ-RELEASE-004**: Release archive names include the package version and
  target platform, and each archive has a SHA-256 checksum file.
- **REQ-RELEASE-005**: GitHub Actions creates draft GitHub Releases for version
  tags with prebuilt archives for common Linux and macOS targets.
- **REQ-RELEASE-006**: GitHub Actions delegates macOS packaging to the local
  release script, and only attaches archives whose extracted binaries pass
  strict ad-hoc signature verification.
- **REQ-RELEASE-007**: Release artifacts are built for hash-verifying CLI and
  package-manager installation. Browser/Finder distribution of quarantined
  archives is outside the supported release contract.
- **REQ-INSTALL-001**: `install.sh` defaults to the latest stable GitHub Release
  and selects the archive matching the host operating system and CPU
  architecture.
- **REQ-INSTALL-002**: `install.sh` verifies the downloaded archive against its
  release SHA-256 sidecar before installing the binary.
- **REQ-INSTALL-003**: `install.sh` keeps source installation available as an
  explicit fallback for maintainers and unsupported platforms.
- **REQ-PLUGIN-001**: A Claude Code plugin registers a PreToolUse(Bash) hook
  that rewrites the command to run under `janitor`, requiring no per-command
  user action.
- **REQ-PLUGIN-002**: The hook re-injects a shell (`bash -c '<orig>'`) so shell
  operators (`&&`, `|`, `;`) in the original command are preserved (janitor
  execs an argv after `--`, not a shell string).
- **REQ-PLUGIN-003**: A per-session lock file keyed by `session_id` exists
  before any wrapped command runs (janitor tears down immediately if
  `--watch-path` is missing at startup) and is passed via `--watch-path`.
- **REQ-PLUGIN-004**: SessionEnd deletes the lock as a best-effort clean-exit
  teardown; correctness does not depend on it firing.
- **REQ-PLUGIN-005**: The hook fails open -- on any error, unsupported platform,
  or missing `janitor`, the original command runs unmodified.
- **REQ-PLUGIN-006**: The hook does not double-wrap an already-`janitor` command
  and skips configured read-only/trivial patterns.
- **REQ-PLUGIN-007**: The plugin resolves the `claude` session PID (ancestry
  walk, `comm == "claude"`) and passes it via `--watch-pid`, since neither
  parent-PID nor SessionEnd is reliable on a hard session kill.

## Invariants

- `janitor` only signals the process group it created.
- `janitor` blocks `SIGTTOU` around `tcsetpgrp` so reclaiming the controlling
  terminal from a background process group cannot stop `janitor`.
- `janitor` does not try to kill processes that escape into a different session
  or process group.
- Cleanup logic is idempotent; `ESRCH` while signaling means the group already
  drained.
- Parent death is detected as `getppid() != original_parent`, not
  `getppid() == 1`.
- Release automation has no signing or notarization secrets to read, print, or
  persist.
- The macOS binary verified after archive extraction is byte-identical to the
  binary packaged in that archive.
- A GitHub Release remains draft until a maintainer reviews the generated
  artifacts.

## Non-Goals

- No daemon, launchd agent, cgroup manager, or persistent process registry.
- `janitor` does not allocate a pseudo-terminal or proxy child I/O; it only
  transfers foreground ownership of the controlling terminal it already
  inherited on standard input.
- No Windows support in this implementation.
- `--poll-ms` remains accepted for CLI compatibility, but it is not the idle
  wait mechanism on supported event backends.
- No attempt to recover children that deliberately call `setsid()` without their
  own nested janitor.
- No Developer ID identity, Apple notarization, Gatekeeper approval, signed
  macOS `.pkg`, or browser/Finder distribution contract.
- No Windows binary release until the implementation supports Windows process
  supervision semantics.

## Acceptance Criteria

- [x] `janitor -- sh -c 'exit 7'` exits with status 7.
- [x] `janitor --version`, `janitor -V`, and `janitor version` print the
      `janitor <version> (<sha>)` banner and exit 0.
- [x] Deleting `--watch-path` kills a TERM-ignoring descendant with `SIGKILL`.
- [x] Sending `SIGTERM` to `janitor` kills a TERM-ignoring descendant with
      `SIGKILL`.
- [x] Parent process exit kills a TERM-ignoring descendant with `SIGKILL`.
- [x] Killing a `--watch-pid` process kills a TERM-ignoring descendant with
      `SIGKILL`.
- [x] `zig build test` runs unit tests and the e2e process tests.
- [x] `zig build fmt` passes.
- [x] Supported platforms use kqueue/epoll event waits instead of idle polling.
- [ ] With a controlling terminal, the child process group becomes the
      terminal's foreground process group after spawn, and the original
      foreground process group is restored after teardown.
- [ ] Non-terminal standard input leaves terminal foreground state untouched
      (the `sh`-based teardown e2e tests keep passing unchanged).
- [x] Local macOS release automation has a syntax check and dry-run path that
      proves credential-free ad-hoc signing and archive-roundtrip verification.
- [ ] Draft GitHub Release automation builds ReleaseSafe archives for common
      Linux and macOS targets with SHA-256 checksums.
- [x] `install.sh` defaults to the latest stable GitHub Release asset, verifies
      checksums, and installs the selected binary.
- [x] Release documentation describes the package-manager distribution boundary
      and credential-free ad-hoc signature verification.
- [x] `janitor cc-hook pretooluse` rewrites a Bash command under `janitor` and
      fails open on malformed input.
- [x] The Claude Code plugin manifest and hooks JSON are valid and register the
      expected hooks.

## Test Traceability

- REQ-JANITOR-001: `src/root.zig` parse tests.
- REQ-JANITOR-002, REQ-JANITOR-004, REQ-JANITOR-006,
  REQ-JANITOR-007: `src/e2e.zig` `testWatchPathKillsProcessGroup`.
- REQ-JANITOR-005, REQ-JANITOR-006, REQ-JANITOR-007:
  `src/e2e.zig` `testSignalKillsProcessGroup`.
- REQ-JANITOR-003, REQ-JANITOR-006, REQ-JANITOR-007:
  `src/e2e.zig` `testParentDeathKillsProcessGroup`.
- REQ-JANITOR-014: `src/root.zig` parse tests, `src/e2e.zig`
  `testWatchPidKillsProcessGroup`.
- REQ-JANITOR-015: `src/root.zig` `versionLine` test, `src/e2e.zig`
  `testVersionCommand`.
- REQ-JANITOR-016: `src/check_plugin_version.zig` and `zig build
  check-plugin-version`.
- REQ-JANITOR-009: `src/e2e.zig` `testNormalExit`.
- REQ-JANITOR-010, REQ-JANITOR-011, REQ-JANITOR-012: `src/root.zig` watcher
  backend selection, plus native and cross-target builds.
- REQ-JANITOR-013: `src/e2e.zig` `testInteractiveForegroundHandoff`.
- REQ-RELEASE-001, REQ-RELEASE-002, REQ-RELEASE-003, REQ-RELEASE-004:
  `scripts/release-macos.sh`, `sh -n scripts/release-macos.sh`, and
  `scripts/release-macos.sh --dry-run --target aarch64-macos`.
- REQ-RELEASE-005, REQ-RELEASE-006, REQ-RELEASE-007:
  `scripts/test-release-automation.sh` and `.github/workflows/release.yml`.
- REQ-INSTALL-001, REQ-INSTALL-002, REQ-INSTALL-003: `install.sh`, `sh -n
  install.sh`, `JANITOR_INSTALL_DRY_RUN=1 ./install.sh`, and
  `JANITOR_INSTALL_FROM_SOURCE=1 ./install.sh`.
- REQ-PLUGIN-001, REQ-PLUGIN-002, REQ-PLUGIN-006: `src/cc_hook.zig` `decide`,
  `matchesSkip`, `buildWrappedCommand`, and `singleQuoteEscape` tests; plus
  `plugin/hooks/hooks.json`.
- REQ-PLUGIN-003, REQ-PLUGIN-004: `src/cc_hook.zig` `lockPathForBase` test and
  `cc-hook session-end` lock deletion; plus `plugin/hooks/hooks.json`.
- REQ-PLUGIN-005: `src/cc_hook.zig` `parsePreToolUse` lenient/defaulting tests
  and the fail-open `main`; plus `plugin/hooks/hooks.json`
  (`janitor cc-hook ... 2>/dev/null || true`).
- REQ-PLUGIN-007: `src/cc_hook.zig` `resolveClaudePidWalk` and `isShellComm`
  tests.
