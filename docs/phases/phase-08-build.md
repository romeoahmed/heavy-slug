# Phase 08: Build System Decomposition

## Goal

Make `build.zig` orchestration-only and move implementation details into `build/` modules.

## Tasks

1. Add `build/deps.zig` for options and dependency resolution.
2. Add `build/c_libs.zig` for FreeType, HarfBuzz, GLFW, and translate-C.
3. Add `build/shaders.zig` for Slang compilation and ABI generation.
4. Add `build/backends.zig` for core, Vulkan, and Metal modules.
5. Add `build/demos.zig` for demo executables.

## Acceptance Criteria

- Lazy dependencies remain lazy.
- Build options keep their existing command-line names unless intentionally changed.
- ThinLTO behavior remains explicit and platform-aware.

## Verification

```bash
zig build
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build shaders
zig build metal-shaders
zig build -Doptimize=ReleaseFast
```

## Dependencies

Phases 05-07.
