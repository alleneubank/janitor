# zig-template

Zig project template with agentic-first tooling, Nix dev environment, and CI.

**[SETUP.md](SETUP.md)** — step-by-step instructions to create a new project from this template.

## Features

- **Zig 0.15+** via [mitchellh/zig-overlay](https://github.com/mitchellh/zig-overlay)
- **ziglint** static analysis (prebuilt binary)
- **zigdocs** via built-in autodoc (`zig build docs`)
- **ZLS** language server in dev shell
- **lefthook** git hooks (format, lint, test)
- **GitHub Actions** CI (test, lint, fmt, docs)
- **Nix flake** reproducible dev environment
- **CLAUDE.md** + **AGENTS.md** for AI-assisted development

## Quick Start

```bash
nix develop        # enter dev shell
zig build          # build library + executable
zig build run      # run the executable
zig build test     # run all tests
zig build docs     # generate documentation
zig build fmt      # check formatting
ziglint            # run linter
lefthook install   # setup git hooks
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
SETUP.md           # Template setup guide (delete after use)
```

## Requirements

- [Nix](https://nixos.org/download/) with flakes enabled

## License

MIT
