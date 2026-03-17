# Template Setup

How to create a new project from this template. Delete this file when done.

## 1. Create your repo

**GitHub UI:** Click **"Use this template"** > **"Create a new repository"**

**CLI:**
```bash
gh repo create my-project --template 0xbigboss/zig-template --public --clone
cd my-project
```

## 2. Rename the project

Replace all template references with your project name. Use lowercase-with-hyphens for the project name and underscores for the Zig module name.

Example: renaming to `my-tool` / `my_tool`:

### `build.zig`
```zig
// Line 8: module name
const mod = b.addModule("my_tool", .{
// Line 15: executable name
.name = "my-tool",
// Line 21: import name
.{ .name = "my_tool", .module = mod },
```

### `build.zig.zon`
```zig
.name = .my_tool,
```

### `src/main.zig`
```zig
const lib = @import("my_tool");
```

### `src/root.zig`
Update the doc comment on line 1:
```zig
//! my-tool library.
```

### `flake.nix`
```nix
description = "my-tool — short description";
```

## 3. Enter the dev shell

```bash
nix develop
```

## 4. Verify

```bash
zig build test  # should pass
zig build run   # should print version
```

## 5. Update documentation

- **README.md** — rewrite to describe your project (remove template features list)
- **CLAUDE.md** — update project name, description, and conventions as your project evolves
- **LICENSE** — verify copyright holder and year

## 6. Delete this file

```bash
rm SETUP.md
git add -A && git commit -m "init: set up project from zig-template"
```

## What to keep

- `AGENTS.md` symlink — some AI tools look for this instead of `CLAUDE.md`
- `.ziglint.zon` — linter config, customize rules as needed
- `lefthook.yml` — git hooks for fmt/lint/test on pre-commit
- `.github/workflows/` — CI pipeline
