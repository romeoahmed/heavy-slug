# Phase 09: Demo Unification and Documentation

## Goal

Make Vulkan and Metal demos differ only in host setup and target submission.

## Tasks

1. Move shared scene/input code to `src/demo/common/`.
2. Move Vulkan demo host code to `src/demo/vulkan/`.
3. Move Metal demo host code to `src/demo/metal/`.
4. Update README examples for the new API.
5. Update AGENTS.md and CHANGELOG.md.

## Acceptance Criteria

- Both demos render the same content through the same high-level renderer API.
- GLFW remains demo-only.
- Docs match actual files and commands.

## Verification

```bash
zig build test
zig build run -Ddemo=true -Ddemo-backend=metal4
```

## Dependencies

Phases 06-07.
