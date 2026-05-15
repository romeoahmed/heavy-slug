# Phase 03: CoverageBlob and CPU Reference

## Goal

Make the blob format a first-class owned module with CPU encode/decode/reference coverage.

## Tasks

1. Add `src/core/blob/format.zig` with all layout constants and header structs.
2. Add `src/core/blob/encode.zig` for span-to-blob encoding.
3. Add `src/core/blob/decode.zig` for test/debug decoding.
4. Add `src/core/blob/hband.zig` for candidate indexing.
5. Add `src/core/blob/reference.zig` for CPU analytic coverage.
6. Remove blob layout constants from outline code.

## Acceptance Criteria

- Encoder and decoder round trip generated and real glyph outlines.
- H-band candidate sets are tested as supersets, never correctness boundaries.
- CPU reference tests cover high zoom and boundary-touching cases.

## Verification

```bash
zig build test
```

## Dependencies

Phase 02.
