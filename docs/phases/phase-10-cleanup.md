# Phase 10: Final Cleanup and Quality Gate

## Goal

Remove old modules, aliases, generated artifacts, and compatibility shims after the new architecture is complete.

## Tasks

1. Delete old source paths that have moved.
2. Remove transitional public exports.
3. Clean stale documentation.
4. Check ignored/generated artifacts.
5. Run final build, shader, backend, and release gates.

## Acceptance Criteria

- No source-level `@cImport`.
- No old renderer/backend responsibilities remain in legacy paths.
- No `.DS_Store`, `.zig-cache`, `zig-out`, or `zig-pkg` artifacts are tracked.
- Public exports are deliberate and documented.

## Verification

```bash
zig fmt --check build.zig build/ src/ tools/
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build shaders
zig build metal-shaders
zig build -Doptimize=ReleaseFast
git diff --check
```

## Dependencies

All prior phases.
