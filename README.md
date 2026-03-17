# zig-template

Zig project template with agentic-first tooling, Nix dev environment, and CI.

## Features

- **Zig master** via [mitchellh/zig-overlay](https://github.com/mitchellh/zig-overlay)
- **ziglint** static analysis (prebuilt binary)
- **zigdocs** via built-in autodoc (`zig build docs`)
- **ZLS** language server in dev shell
- **lefthook** git hooks (format, lint, test)
- **GitHub Actions** CI (test, lint, fmt, docs)
- **Nix flake** reproducible dev environment
- **CLAUDE.md** + **AGENTS.md** for AI-assisted development

## Getting Started

### Use as template

1. Click **"Use this template"** on GitHub (or `gh repo create my-project --template 0xbigboss/zig-template --public --clone`)
2. Replace `zig-template` / `zig_template` with your project name in `build.zig`, `build.zig.zon`, and `src/main.zig`
3. Enter the dev shell:

```bash
nix develop
```

### Build and run

```bash
zig build          # build library + executable
zig build run      # run the executable
zig build test     # run all tests
zig build docs     # generate documentation
zig build fmt      # check formatting
ziglint            # run linter
```

### Setup git hooks

```bash
lefthook install
```

## Project Structure

```
src/
  root.zig         # Library public API
  main.zig         # Executable entry point
build.zig          # Build script
build.zig.zon      # Package manifest
.ziglint.zon       # Linter config
flake.nix          # Nix dev environment
CLAUDE.md          # AI agent instructions
AGENTS.md          # -> CLAUDE.md (symlink)
```

## Requirements

- [Nix](https://nixos.org/download/) with flakes enabled

## License

MIT
