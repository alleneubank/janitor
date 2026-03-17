# zig-template

Zig project template with agentic-first tooling.

## Quick Reference

- **Enter dev shell:** `nix develop` (or `direnv allow` with .envrc)
- **Build:** `zig build`
- **Run:** `zig build run`
- **Test:** `zig build test`
- **Format check:** `zig build fmt`
- **Lint:** `ziglint`
- **Generate docs:** `zig build docs` (output in `zig-out/docs/`)
- **All checks:** `zig build test && zig build fmt && ziglint`

## Project Layout

```
src/root.zig     # Library entry point (public API for consumers)
src/main.zig     # Executable entry point (imports library)
build.zig        # Build script (test, docs, fmt, run steps)
build.zig.zon    # Package manifest (name, version, deps)
.ziglint.zon     # Linter configuration
flake.nix        # Nix dev environment (zig master, zls, ziglint)
```

## Build Steps

| Command | Description |
|---------|-------------|
| `zig build` | Build library and executable |
| `zig build run` | Run the executable |
| `zig build run -- args` | Run with arguments |
| `zig build test` | Run all unit tests |
| `zig build docs` | Generate autodoc HTML |
| `zig build fmt` | Check source formatting |

## Tooling

- **Zig** — master via `mitchellh/zig-overlay` (nix flake)
- **ZLS** — language server from nixpkgs-unstable
- **ziglint** — static analysis (prebuilt binary via nix)
- **lefthook** — git hooks (fmt, lint, test on pre-commit)
- **zig fmt** — canonical formatter (built into zig)

## Conventions

- Tests live alongside code in `test` blocks within `.zig` files
- Library public API is in `src/root.zig`; internal modules are separate `.zig` files imported with `@import`
- Use `std.log.scoped` for namespaced logging
- Pass allocators explicitly — never use global state for allocation
- Define explicit error sets — avoid `anyerror`
- Prefer `const` over `var`; prefer slices over raw pointers

## Template Usage

1. Create a new repo from this template on GitHub
2. Replace `zig-template` and `zig_template` with your project name in:
   - `build.zig` (module name, artifact names)
   - `build.zig.zon` (package name)
   - `src/main.zig` (import name)
3. Run `nix develop` to enter the dev shell
4. Run `zig build test` to verify everything works
