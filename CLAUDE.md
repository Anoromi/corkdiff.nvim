# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Critical Rules (from AGENTS.md)

- **NEVER commit code unless the user explicitly requests it.** After completing changes, STOP and wait for user to say "commit". Each commit request authorizes only ONE commit operation.
- Never add trailing spaces to any line in any file.

## Build, Test, and Lint

```bash
make              # Build the C diff library
make test         # Run all tests (C + Lua)
make test-c       # Run C unit tests only
make test-lua     # Run Lua integration tests only
make lint         # Check Lua code style (stylua --check lua)
make format       # Format Lua code (stylua lua)
make clean        # Clean build artifacts
make bump-patch   # Bump patch version
```

The `Makefile` is auto-generated from `CMakeLists.txt`. Always regenerate it via `cmake -B build` if it becomes stale.

Lua code style: 2-space indent, 180-column width, double quotes, Unix line endings (`.stylua.toml`).

## Architecture Overview

### Two-layer design

1. **C diff engine** (`libvscode-diff/`) — computes diffs using Myers algorithm with VSCode-parity output. Compiled to a shared library (`libvscode_diff_<version>.so/dylib/dll`) and called from Lua via FFI.

2. **Lua plugin** (`lua/codediff/`) — handles UI, git operations, configuration, and session lifecycle. Lazy-loaded on first `:CodeDiff` invocation.

### Plugin entry flow

```
plugin/codediff.lua          ← Neovim auto-loads this (registers :CodeDiff, highlights, virtual scheme)
  → lua/codediff/init.lua    ← Public Lua API (setup, navigation)
  → lua/codediff/commands.lua ← Dispatches 5 subcommands: merge, file, dir, history, install
```

### Core modules (`lua/codediff/core/`)

| File | Role |
|------|------|
| `diff.lua` | FFI bridge to C library; `compute_diff()` |
| `git.lua` | Async git operations (uses `vim.system`) |
| `config.lua` | All defaults; `setup(opts)` merges via `vim.tbl_deep_extend` |
| `installer.lua` | Auto-downloads versioned C binary from GitHub releases |
| `virtual_file.lua` | Registers a custom buffer scheme for git history files |
| `args.lua` | Parses `:CodeDiff` command arguments |

### UI modules (`lua/codediff/ui/`)

| Path | Role |
|------|------|
| `core.lua` | Diff rendering engine — applies line/char extmarks |
| `view/` | View router: chooses side-by-side vs inline layout |
| `lifecycle/` | Per-tabpage session state (config + mutable state) |
| `explorer/` | Git status explorer panel (list/tree view) |
| `history/` | Commit history panel |
| `conflict/` | Merge conflict resolution UI |
| `inline.lua` | Unified/inline diff layout |
| `highlights.lua` | Defines all highlight groups |
| `layout.lua` | Window layout management |
| `auto_refresh.lua` | Watches buffer changes to live-update the diff |
| `keymap_help.lua` | Floating help window (`g?`) |

### Session state

State is stored **per tabpage** in `lua/codediff/ui/lifecycle/`. There is an immutable session config and a mutable state accessed via typed accessor functions. Do not store session state as module-level variables.

### Configuration

All user-facing options live in `lua/codediff/config.lua` (`M.defaults`). Key namespaces: `highlights`, `diff`, `explorer`, `history`, `keymaps`. Keymaps are split into `view`, `explorer`, `history`, and `conflict` sub-tables.

### C library versioning

`VERSION` file is the single source of truth. The C library filename includes the version (e.g., `libvscode_diff_2.39.1.so`). `lua/codediff/core/installer.lua` and `lua/codediff/core/diff.lua` both read this version at runtime. When bumping version, run `make bump-patch/minor/major` rather than editing `VERSION` directly.

## Tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Each spec is in `tests/*_spec.lua`. Shared helpers (git repo setup, temp dirs) are in `tests/helpers.lua`. The test runner is `tests/run_plenary_tests.sh`.

To run a single Lua spec file:
```bash
nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/<spec_file>.lua"
```
