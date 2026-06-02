# janitor

Zig CLI that supervises a child process group and drains it when the wrapper's
parent or watched worktree disappears.

## Commands

- Build: `zig build`
- Run: `zig build run -- --help`
- Test: `zig build test`
- Format check: `zig build fmt`
- Docs: `zig build docs`

## Project Layout

```
src/root.zig     # Library API, CLI parsing, process supervision
src/main.zig     # Executable entry point
src/e2e.zig      # End-to-end test runner invoked by zig build test
SPEC.md          # Requirements and traceability
```

## Conventions

- Keep side effects at the supervision boundary; parsing and status encoding
  should stay testable as pure functions.
- Teardown must observe process-group liveness, not only the direct child PID.
- Do not add test-only behavior to `src/root.zig`; e2e tests must exercise the
  compiled `janitor` binary.
- Prefer explicit errors and small tagged unions for lifecycle state.
