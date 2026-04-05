# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**heavy-slug** is a Zig project with a library module (`root.zig`) and CLI executable (`main.zig`). Requires Zig 0.16.0-dev.3091+.

## Commands

```bash
# Format
zig fmt

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
- `src/font/ft.zig` — FreeType @cImport wrapper (Library init/deinit)
- `src/font/hb.zig` — HarfBuzz @cImport wrapper (Buffer create/destroy/shape)
- `build.zig` — defines both the module (importable by other packages) and the executable target
- `build.zig.zon` — package manifest (name: `heavy_slug`, version: 0.0.0, deps: FreeType 2.14.3, HarfBuzz 14.1.0)
- `zig-pkg/` — local package cache (FreeType/HarfBuzz source tarballs by hash)

Key patterns in use:
- Unit tests embedded in source files (`test` blocks); fuzz tests via `std.testing.Smith`
- Test discovery: root.zig must `test { _ = @import("font/ft.zig"); }` for nested module tests
- C libs built via `buildFreetype()` / `buildHarfbuzz()` in build.zig, linked to heavy_slug module

## Zig 0.16.0-dev gotchas

- `b.addLibrary(.{ .linkage = .static })` not `b.addStaticLibrary()` (removed in 0.16)
- `@cImport` needs explicit `mod.addIncludePath()` — `linkLibrary` alone doesn't propagate headers
