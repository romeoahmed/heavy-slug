# Phase 01: Core Types, Units, and Public API

## Goal

Introduce the new public vocabulary before moving the renderer internals.

## Tasks

1. Add `src/core/types.zig` for `Color`, `Transform`, `Viewport`, `Projection`, `FillRule`, `FontHandle`, and `GlyphKey`.
2. Add `src/core/units.zig` for explicit conversions among pixels, HarfBuzz 26.6 values, blob quantized units, and projection scaling.
3. Add `src/core/errors.zig` for shared error names.
4. Update `src/root.zig` to export the new stable types.
5. Keep old modules buildable until their replacements land.

## Acceptance Criteria

- Public users can import stable names from `heavy_slug`.
- PGA `Motor` remains available internally but is no longer the preferred public transform name.
- Unit conversion tests cover projection scaling and HarfBuzz 26.6 conversion.

## Verification

```bash
zig fmt build.zig src/ tools/
zig build test
```

## Dependencies

Phase 00.
