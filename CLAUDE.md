# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**heavy-slug** is a Zig project with a library module (`root.zig`) and CLI executable (`main.zig`). Requires Zig 0.16.0-dev.3091+.

## Commands

```bash
# Build
zig build

# Run executable
zig build run
zig build run -- arg1 arg2

# Run all tests
zig build test

# Run with fuzzing
zig build test -- --fuzz

# Build with optimization
zig build -Doptimize=ReleaseFast   # or ReleaseSafe, ReleaseSmall
zig build -Dtarget=<target>
```

## Commits

All commits require: `git commit -s -S` (Signed-off-by + GPG signature) with `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` in the message trailer.

## Architecture

- `src/root.zig` — library module, exported as `heavy_slug` for external use
- `src/main.zig` — CLI executable that imports the library module
- `build.zig` — defines both the module (importable by other packages) and the executable target
- `build.zig.zon` — package manifest (name: `heavy_slug`, version: 0.0.0, no external deps)

Key patterns in use:
- Arena allocators with `defer` for lifetime-scoped memory
- Buffered writers with explicit flush for stdout
- Unit tests embedded in source files (`test` blocks); fuzz tests via `std.testing.Smith`
