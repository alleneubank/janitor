# janitor Tilt extension SPEC

Tilt `serve_cmd` processes are easy to leak because Tilt can be killed by a
terminal crash, `kill -9`, or a deleted worktree before it runs normal resource
teardown. The extension provides a drop-in `local_resource` wrapper that starts
selected local commands under `janitor`, so the command's process group is
drained when Tilt or the watched worktree disappears.

The extension is distributed from this repository as `tilt/janitor/`, matching
the `tilt-dev/tilt-extensions` layout so it can be loaded as a self-hosted
custom extension repo or vendored directly into a project.

## Domain Model

- **Extension module**: `tilt/janitor/Tiltfile`, loaded by a project Tiltfile.
- **Wrapped resource**: a `local_resource` call made through
  `janitor_local_resource`.
- **Command input**: a Tilt command supplied as either a string or an argv list.
- **Wrapped argv**: the list passed to Tilt after adding
  `janitor --watch-path PATH --grace-ms MS --`.
- **Watch path**: the path janitor observes for disappearance, defaulting to
  `config.main_dir`.
- **Grace window**: the extension-level drain window in milliseconds, defaulting
  to 5000.
- **Resolved janitor binary**: the cached module-level binary path selected at
  Tiltfile load, unless a per-call `janitor_bin` override is passed.
- **Outer guard command**: the shell command returned by `janitor_tilt_up_cmd`
  for wrapping Tilt itself outside a Tiltfile.

## Requirements

- **REQ-TILT-001**: `janitor_local_resource(name, cmd=None, serve_cmd=None,
  grace_ms=5000, watch_path=None, wrap_serve_cmd=True, wrap_cmd=False,
  janitor_bin=None, **kwargs)` is a drop-in for `local_resource`; all
  non-command kwargs are forwarded unchanged, and only command keys the caller
  passed are set.
- **REQ-TILT-002**: `serve_cmd` is wrapped by default; `cmd` is wrapped only when
  `wrap_cmd=True`.
- **REQ-TILT-003**: a string command is wrapped as
  `janitor ... -- sh -c "<cmd>"`; a list command is wrapped as
  `janitor ... -- <argv...>`.
- **REQ-TILT-004**: `watch_path` defaults to `config.main_dir`; `grace_ms`
  defaults to 5000.
- **REQ-TILT-005**: the janitor binary is resolved in order from
  `janitor_bin` or `JANITOR_BIN`, `PATH`, `$PREFIX/bin`, auto-install, then an
  actionable failure. A per-call `janitor_bin` (or a binary already on
  `PATH`/`$PREFIX/bin`) always wins and never triggers a network install:
  auto-install is deferred to first wrapped use rather than run at module load,
  so explicit and offline/vendored configurations are never preempted.
  Auto-install is on by default on macOS/Linux, drives `install.sh` with
  SHA-256-verified release archives, honors `JANITOR_VERSION` and `PREFIX`, is
  idempotent, and resolves to `$PREFIX/bin/janitor`.
- **REQ-TILT-006**: `JANITOR_AUTO_INSTALL=0` or an unsupported non-POSIX
  platform disables auto-install and yields a fail-fast install message; Windows
  and `*_bat` commands are not wrapped by this Unix-only extension.
- **REQ-TILT-007**: `janitor_tilt_up_cmd()` returns the recommended outer guard
  command string `janitor ... -- tilt up`, with the watch path shell-quoted so
  it is safe to paste into a Makefile, justfile, or shell alias.

## Invariants

- String command inputs preserve Tilt's shell semantics by remaining under
  `sh -c`.
- List command inputs preserve argv semantics and are never shell-joined.
- The only load-time side effect is a non-installing binary lookup
  (`command -v` plus a `$PREFIX/bin` stat); the network auto-install runs lazily
  at first wrapped use so an explicit `janitor_bin` is never preempted.
- The outer-guard string shell-quotes the watch path so it cannot alter argv or
  inject shell syntax when pasted into a shell.
- `janitor_wrap` is deterministic for explicit `watch_path`, `grace_ms`, and
  `janitor_bin` inputs.
- The extension never adds Windows batch command wrapping because janitor does
  not implement Windows process supervision.

## Non-Goals

- No upstream `tilt-dev/tilt-extensions` publication is required.
- No Windows support or `cmd_bat`/`serve_cmd_bat` support.
- No attempt to re-exec a running Tilt process from inside a Tiltfile.
- No test-only branches in the extension implementation.

## Acceptance Criteria

- [x] `JANITOR_BIN=/usr/bin/true tilt alpha tiltfile-result -f
      tilt/janitor/test/Tiltfile` evaluates load-time wrapper assertions.
- [x] `sh -n tilt/janitor/test/drain_test.sh` verifies the manual drain test is
      syntactically valid POSIX sh.
- [ ] Running `tilt/janitor/test/drain_test.sh` manually kills Tilt with
      `SIGKILL` and observes the wrapped sleeper process group drain.
- [x] All extension deliverables live under `tilt/janitor/`.

## Test Traceability

- REQ-TILT-001: `tilt/janitor/test/drain_test.sh` creates a real
  `janitor_local_resource` and relies on forwarded local-resource behavior.
- REQ-TILT-002: `tilt/janitor/test/drain_test.sh` uses default `serve_cmd`
  wrapping without opting into `cmd` wrapping.
- REQ-TILT-003: `tilt/janitor/test/Tiltfile` asserts exact string-command and
  list-command argv output.
- REQ-TILT-004: `tilt/janitor/test/Tiltfile` asserts explicit grace and watch
  path behavior; `tilt/janitor/test/drain_test.sh` exercises the 5000 default
  through module load and a resource-level short override.
- REQ-TILT-005: `tilt/janitor/test/resolve_test.sh` case A proves an explicit
  `janitor_bin` resolves in an isolated env (no janitor on PATH, empty
  `$PREFIX`) without invoking the auto-installer, even with auto-install enabled;
  `tilt/janitor/test/Tiltfile` passes explicit `janitor_bin` for argv assertions.
- REQ-TILT-006: `tilt/janitor/test/resolve_test.sh` case B proves that with
  janitor absent and `JANITOR_AUTO_INSTALL=0`, evaluation fails fast with the
  actionable install message and never calls curl; non-POSIX platforms are
  guarded in both test scripts.
- REQ-TILT-007: `tilt/janitor/test/Tiltfile` asserts the exact
  `janitor_tilt_up_cmd()` string, including shell-quoting of watch paths that
  contain spaces and single quotes.
