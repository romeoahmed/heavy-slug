# Phase 02: Font and Outline Pipeline

## Goal

Separate font loading, shaping, raw outline capture, and cubic regularization.

## Tasks

1. Move FreeType wrapper responsibilities into `src/core/font/freetype.zig`.
2. Move HarfBuzz wrapper responsibilities into `src/core/font/harfbuzz.zig`.
3. Add `src/core/font/font_system.zig` for face/font lifetime.
4. Add `src/core/font/shape.zig` for reusable shaping buffers and shaped glyph slices.
5. Add `src/core/outline/stream.zig` for move/line/quad/cubic/close commands.
6. Add `src/core/outline/regularize.zig` for cubic span preparation.
7. Keep native cubic callbacks from HarfBuzz as the source of truth.

## Acceptance Criteria

- Shaping can be tested without blob encoding.
- Outline capture can be tested without GPU upload.
- Regularized cubic spans are monotone and quantizable.
- Variation key plumbing exists in `GlyphKey`.

## Verification

```bash
zig build test
```

## Dependencies

Phase 01.
