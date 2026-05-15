# Phase 05: Shader Modules and ABI

## Goal

Split Slang into backend-neutral coverage code and backend-specific resource shims.

## Tasks

1. Move shared shader structs into `shaders/core/abi.slang`.
2. Move coverage math into `shaders/core/coverage_integral.slang`.
3. Move blob decode into `shaders/core/coverage_blob.slang`.
4. Add Vulkan and Metal resource shims.
5. Keep entry points thin in `shaders/entries/`.
6. Update build shader paths and reflection generation.

## Acceptance Criteria

- No backend conditionals in coverage math.
- CPU ABI structs still come from Slang reflection.
- SPIR-V 1.6 and Metal 4 shader outputs compile.

## Verification

```bash
zig build shaders
zig build metal-shaders
zig build test
```

## Dependencies

Phase 04.
