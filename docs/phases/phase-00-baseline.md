# Phase 00: Baseline and Guardrails

## Goal

Capture the current working state before moving code. This phase prevents refactor regressions from being mistaken for pre-existing behavior.

## Tasks

1. Record current build and test commands.
2. Verify core, backend, shader, and release builds where supported.
3. Keep the existing API examples as migration input only.

## Acceptance Criteria

- Core tests pass.
- Vulkan and Metal backend compile tests pass on supported hosts.
- Shader build steps pass.
- No implementation files are changed in this phase.

## Verification

```bash
zig fmt --check build.zig src/ tools/
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build shaders
zig build metal-shaders
zig build -Doptimize=ReleaseFast
git diff --check
```

## Dependencies

None.
