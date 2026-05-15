# Phase 06: Vulkan Backend Rewrite

## Goal

Rebuild Vulkan around explicit frame slots, opaque glyph refs, and deferred descriptor retirement.

## Tasks

1. Move Vulkan code under `src/backends/vulkan/`.
2. Add `Frame`, `Target`, `GlyphStore`, and `Renderer` modules.
3. Make command storage frame-protected.
4. Defer descriptor slot reuse until frame completion.
5. Update Vulkan demo host code under `src/demo/vulkan/`.

## Acceptance Criteria

- Vulkan implements the backend contract.
- Descriptor refs are opaque to core.
- Per-frame command writes cannot race GPU reads.
- Public Vulkan API matches the new renderer/frame/target shape.

## Verification

```bash
zig build test -Dvulkan=true
zig build -Doptimize=ReleaseFast -Dvulkan=true
```

## Dependencies

Phase 05.
