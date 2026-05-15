# Phase 04: Renderer Core and Backend Contract

## Goal

Replace implicit `anytype` backend calls with an explicit compile-time backend contract.

## Tasks

1. Add `src/core/render/backend_contract.zig`.
2. Add `src/core/render/text_batch.zig` for per-frame command writing.
3. Add `src/core/render/renderer_core.zig` for font, cache, glyph store, and batch orchestration.
4. Add `src/core/cache/retirement.zig` for frame-token deferred frees.
5. Convert glyph references to backend-opaque `GlyphRef`.
6. Add fake backend tests for cache/upload/retirement behavior.

## Acceptance Criteria

- Missing backend declarations fail at compile time.
- Core stores `GlyphRef` opaquely.
- Evictions are retired by frame token, not freed immediately.
- Fake backend proves empty glyphs, cache hits, and deferred frees.

## Verification

```bash
zig build test
```

## Dependencies

Phase 03.
