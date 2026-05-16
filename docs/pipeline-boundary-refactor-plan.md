# Pipeline Boundary Refactor Plan

## Status

Implemented. This is the follow-up convergence record after `docs/architecture-refactor-spec.md`.

## Date

2026-05-16

## Scope

The repository now routes the runtime path through the intended boundary flow:

```text
FontSystem
  -> ShapePlan
  -> OutlineStream
  -> RegularizedCubicSpans
  -> CoverageBlob
  -> GlyphStore
  -> TextBatch
  -> BackendFrame
  -> GPU submit
```

Breaking changes were used to remove implicit ownership, hidden HarfBuzz coupling, and backend-specific command plumbing from the core.

## Implementation Audit

The public root in `src/root.zig` exports stable types and still exposes `core` and `gpu` for expert/internal users. Backends are opt-in under `src/backends/`, and GLFW remains demo-only through `build/demos.zig`.

`FontSystem` in `src/core/font/font_system.zig` owns FreeType library lifetime and loads `LoadedFont` values. `ShapePlan` in `src/core/font/shape.zig` owns reusable HarfBuzz buffer state. `RendererCore` uses `LoadedFont.shape()` and no longer manipulates `hb.Buffer` directly.

`OutlineCapture` in `src/core/outline/encode.zig` writes HarfBuzz draw callbacks into `OutlineStream`. `src/core/outline/regularize.zig` converts native move/line/quadratic/cubic segments into `RegularizedCubicSpan` values split for extrema, inflections, and quantized monotonicity.

`CoverageBlob` is an owned core type in `src/core/blob/format.zig`. Blob encoding lives in `src/core/blob/encode.zig` and accepts regularized cubic spans. `EncodedGlyph` owns a `CoverageBlob`; `hb.Blob` is not part of the core glyph/cache/upload boundary.

`GlyphStore` owns cache metadata, byte-pool allocations, and deferred retirement. `TextBatch` in `src/core/render/text_batch.zig` is a borrowed fixed-capacity writer over backend-owned command memory and is used by both Vulkan and Metal frames.

Vulkan and Metal both expose `Renderer.beginFrame()`, `Frame.drawText()`, and `Frame.submit()`. The backend contract uses ownership-oriented `uploadBlob` and `retireBlob` methods, while command storage belongs to backend frames through `TextBatch`.

Shaders are already split into backend resource shims and shared coverage code. `slug_fragment.slang` correctly treats h-band as an optimization only: single-band fragments use candidates, while multi-band fragments fall back to full scan.

## Architecture Decisions

- Make owned core types explicit. HarfBuzz and FreeType handles may exist inside font modules, but `CoverageBlob` and render cache boundaries must not expose `hb.Blob`.
- Treat `OutlineStream` as the only raw outline boundary. HarfBuzz callbacks should capture native move, line, quadratic, cubic, and close commands before regularization.
- Treat `RegularizedCubicSpan` as the only geometry accepted by blob encoding. It should be already split for extrema, inflections, degenerates, and quantized monotonicity.
- Keep full-scan analytic cubic coverage as the correctness path. H-band remains a conservative candidate index only.
- Keep backend frames responsible for command storage and submission. `RendererCore` should append commands through a typed writer, not a raw pointer plus mutable glyph count.
- Preserve current build constraints: Zig 0.16, build-system `addTranslateC()`, lazy Vulkan/GLFW dependencies, and demo-only GLFW.

## Dependency Graph

```text
public type cleanup
  -> FontSystem and ShapePlan contracts
    -> OutlineStream production capture
      -> RegularizedCubicSpan production regularizer
        -> owned CoverageBlob encoder and decoder
          -> RendererCore glyph encode/cache path
            -> TextBatch command writer
              -> Vulkan and Metal BackendFrame integration
                -> shader ABI and docs cleanup
```

## Phase 0: Guardrails and Baseline

**Status:** Complete.

**Description:** Freeze behavior before changing boundaries.

**Tasks:**
- Add a short architecture trace test map in docs listing current module responsibilities.
- Add regression fixtures for the current CFF glyph path using `assets/Inter-Regular.otf`.
- Capture the current shader build and backend compile commands as the required gate.

**Acceptance criteria:**
- Current tests and shader builds pass before refactor work begins.
- New tests only describe current behavior; they do not encode old API compatibility.

**Verification:**
- `zig fmt --check build.zig build/ src/ tools/`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- `zig build shaders`
- `zig build metal-shaders`

**Files likely touched:**
- `docs/refactor-traceability.md`
- `src/core/font/glyph.zig`
- `src/core/outline/encode.zig`

## Phase 1: Public API and Type Boundary Cleanup

**Status:** Complete.

**Description:** Decide what is public and make the stable API difficult to misuse.

**Tasks:**
- Review whether `heavy_slug.core` and `heavy_slug.gpu` should remain public convenience exports or move behind narrower named exports.
- Move `FontSource`, `FontOptions`, and future shaping options under the font API while preserving root aliases.
- Replace broad internal error aliases with boundary-specific error sets where useful.

**Acceptance criteria:**
- Root exports document a stable public API and no longer imply that every `core.*` module is public contract.
- Public docs show one Vulkan and one Metal usage path using the same `TextRun` shape.

**Verification:**
- `zig build test`
- Compile examples in README through existing backend module tests where possible.

**Files likely touched:**
- `src/root.zig`
- `src/core/root.zig`
- `src/core/types.zig`
- `src/core/errors.zig`
- `README.md`
- `AGENTS.md`

## Phase 2: FontSystem and ShapePlan

**Status:** Complete.

**Description:** Make font loading and shaping an explicit stage instead of a side effect inside `RendererCore`.

**Tasks:**
- Introduce `src/core/font/shape_plan.zig` with direction, script, language, feature, and buffer reuse policy.
- Let `FontSystem` own FreeType library lifetime and load `LoadedFont` values used by render core.
- Rename or privatize `FontContext`; split it into `LoadedFont`, `GlyphEncoder`, and `ShapePlan` responsibilities.
- Move renderer shaping from `RendererCore.appendRun()` into a font module function that returns a small `ShapedRun` view.

**Acceptance criteria:**
- `RendererCore` no longer manipulates `hb.Buffer` directly.
- Tests cover default shaping, explicit direction/script, empty text, and repeated shaping through one reusable plan.
- Font handles still include `variation_key` in cache keys.

**Verification:**
- `zig build test`
- Add focused tests under `src/core/font/`.

**Files likely touched:**
- `src/core/font/font_system.zig`
- `src/core/font/shape.zig`
- `src/core/font/glyph.zig`
- `src/core/font/root.zig`
- `src/core/render/renderer_core.zig`

## Phase 3: OutlineStream as Production Capture

**Status:** Complete.

**Description:** Make raw outline capture a real boundary.

**Tasks:**
- Move HarfBuzz draw callback wiring into an `OutlineCapture` helper that writes `OutlineStream`.
- Keep native line, quadratic, and cubic commands intact until regularization.
- Remove direct callback writes into `OutlineBuilder.curves`.
- Add debug helpers to dump an `OutlineStream` for one glyph without producing a blob.

**Acceptance criteria:**
- `encodeGlyph()` or its replacement first produces `OutlineStream`.
- Tests prove CFF cubic callbacks and TrueType quadratic callbacks enter the stream as distinct segment variants.
- Empty glyphs produce an empty stream without special-case backend behavior.

**Verification:**
- `zig build test`
- New tests in `src/core/outline/stream.zig` or a new capture module.

**Files likely touched:**
- `src/core/outline/stream.zig`
- `src/core/outline/encode.zig`
- `src/core/font/glyph.zig`
- `src/core/font/harfbuzz.zig`

## Phase 4: RegularizedCubicSpans as Source of Truth

**Status:** Complete.

**Description:** Move all curve splitting and preparation out of blob encoding.

**Tasks:**
- Rename `CubicSpan` to `RegularizedCubicSpan` or expose that name as the production type.
- Move extrema, inflection, degenerate, and post-quantization monotonic splitting from `outline/encode.zig` into `outline/regularize.zig`.
- Store per-span bounds and validation flags on the regularized type.
- Add generated or table-driven tests for flat spans, vertical spans, cusp-like spans, loops split by inflection, and high-zoom near-endpoint cases.

**Acceptance criteria:**
- Blob encoding accepts only `[]const RegularizedCubicSpan`.
- Every span is finite, non-empty, bounded, and monotone enough for shader integration after quantization.
- Regularization tests cover the cases that previously caused zoom-dependent horizontal artifacts.

**Verification:**
- `zig build test`
- Add CPU reference tests comparing regularized spans against full outline point coverage.

**Files likely touched:**
- `src/core/outline/regularize.zig`
- `src/core/outline/area.zig`
- `src/core/outline/root.zig`
- `src/core/outline/encode.zig`
- `src/core/blob/reference.zig`

## Phase 5: Owned CoverageBlob

**Status:** Complete.

**Description:** Move blob ownership into `src/core/blob/` and remove HarfBuzz blob leakage.

**Tasks:**
- Introduce `CoverageBlob` as an owned core type, preferably backed by `[]Texel` or aligned bytes with an explicit `deinit()`.
- Move `encodeCurves()` from `outline/encode.zig` into `blob/encode.zig`.
- Make `BlobView` decode `CoverageBlob` directly and keep raw byte decoding only for shader-upload tests.
- Keep header bases derived from counts and section order.
- Keep h-band data as conservative candidate ids only.

**Acceptance criteria:**
- No `hb.Blob` appears outside HarfBuzz wrapper internals.
- `EncodedGlyph` owns a `CoverageBlob`, not an `hb.Blob`.
- CPU blob encode/decode tests live in `src/core/blob/`.

**Verification:**
- `rg "hb\\.Blob|encodeCurves" src/core`
- `zig build test`
- `zig build shaders`
- `zig build metal-shaders`

**Files likely touched:**
- `src/core/blob/format.zig`
- `src/core/blob/encode.zig`
- `src/core/blob/decode.zig`
- `src/core/blob/hband.zig`
- `src/core/blob/reference.zig`
- `src/core/font/glyph.zig`
- `src/core/outline/encode.zig`

## Phase 6: RendererCore, GlyphStore, and TextBatch

**Status:** Complete.

**Description:** Make command generation an explicit append-only frame stage.

**Tasks:**
- Replace `RendererCore.appendRun(backend, Command, commands, run)` with a writer interface or fixed-capacity `TextBatch(Command)`.
- Make `TextBatch` support borrowed mapped memory so it does not force `ArrayList` allocation.
- Move glyph count and submit-state ownership from backend renderers into `BackendFrame` or `TextBatch`.
- Keep `GlyphStore` responsible only for cache, byte pool, and deferred retirement.

**Acceptance criteria:**
- `RendererCore` appends to a typed command writer and does not know about backend mapped pointer storage.
- Empty glyphs, capacity errors, cache hits, evictions, and frame retirement remain covered by fake-backend tests.
- `TextBatch` is used by both Vulkan and Metal paths.

**Verification:**
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`

**Files likely touched:**
- `src/core/render/renderer_core.zig`
- `src/core/render/text_batch.zig`
- `src/core/render/glyph_store.zig`
- `src/core/render/backend_contract.zig`
- `src/backends/vulkan/renderer.zig`
- `src/backends/metal/renderer.zig`

## Phase 7: BackendFrame and Resource Contracts

**Status:** Complete.

**Description:** Align Vulkan and Metal around the same frame resource model while keeping backend-specific resource binding private.

**Tasks:**
- Replace the current backend contract methods with names that describe ownership: `uploadBlob`, `retireBlob`, `beginBackendFrame`, or an equivalent frame writer contract.
- Keep `GlyphRef` opaque to the core; document Vulkan descriptor-slot refs and Metal byte-offset refs only inside backend modules.
- Ensure zero-glyph submit behavior releases or preserves frame slots consistently across backends.
- Review Metal frame-slot completion and Vulkan `markFrameComplete()` expectations for matching lifetime semantics.

**Acceptance criteria:**
- Backend contract tests prove both pointer and value receiver forms compile.
- Vulkan and Metal expose the same public renderer lifecycle.
- Core tests can exercise backend lifetime through a fake frame implementation.

**Verification:**
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- Manual Metal demo smoke test when touching frame-slot handling.

**Files likely touched:**
- `src/core/render/backend_contract.zig`
- `src/backends/vulkan/renderer.zig`
- `src/backends/vulkan/glyph_store.zig`
- `src/backends/metal/renderer.zig`
- `src/backends/metal/glyph_store.zig`
- `src/backends/metal/bridge.h`
- `src/backends/metal/bridge.mm`

## Phase 8: Shader and ABI Validation

**Status:** Complete.

**Description:** Keep shader behavior stable while CPU boundaries move.

**Tasks:**
- Add a small generated or asserted mapping between `blob/format.zig` constants and `coverage_blob.slang`.
- Keep backend conditionals restricted to resource bindings and entry interface differences.
- Add CPU tests that mirror `slug_fragment.slang` h-band fallback rules: single-band candidate scan, multi-band full scan.
- Add ABI regression tests for `GlyphCommand` and `PushConstants` after `TextBatch` changes.

**Acceptance criteria:**
- CPU and shader blob layouts remain synchronized.
- H-band never becomes a correctness boundary.
- SPIR-V and Metal 4 shader builds pass after every data layout change.

**Verification:**
- `zig build shaders`
- `zig build metal-shaders`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`

**Files likely touched:**
- `shaders/core/coverage_blob.slang`
- `shaders/core/coverage_integral.slang`
- `shaders/entries/slug_fragment.slang`
- `src/core/blob/format.zig`
- `tools/layout_gen.zig`

## Phase 9: Build, CI, and Documentation Cleanup

**Status:** Complete.

**Description:** Keep build and docs aligned with the new boundaries.

**Tasks:**
- Update README architecture text after the production data flow is real.
- Update `docs/refactor-traceability.md` with the new convergence phases.
- Keep `build.zig` orchestration-only and preserve lazy dependencies.
- Add CI commands for any new focused test step if tests become split by module.
- Remove incidental non-source files from repository hygiene if they appear in tracked paths.

**Acceptance criteria:**
- Docs describe the actual runtime path, not aspirational module names.
- CI still supports manual Zig and Slang version selection.
- No generated `zig-out`, `.zig-cache`, shader output, or host metadata is tracked.

**Verification:**
- `zig fmt --check build.zig build/ src/ tools/`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- `zig build -Doptimize=ReleaseFast`
- `git diff --check`

**Files likely touched:**
- `README.md`
- `AGENTS.md`
- `docs/refactor-traceability.md`
- `.github/workflows/test.yaml`
- `.github/scripts/*.sh`
- `.gitignore`

## Checkpoints

### Checkpoint A: After Phases 1-3

- Public API shape is decided.
- `RendererCore` no longer shapes text directly.
- HarfBuzz outline callbacks produce `OutlineStream`.
- Core tests pass.

### Checkpoint B: After Phases 4-5

- Regularized spans are the only blob input.
- `CoverageBlob` is owned by core code and no longer depends on `hb.Blob`.
- CPU reference and blob decode tests pass.
- Shader builds pass.

### Checkpoint C: After Phases 6-7

- `TextBatch` is in the production render path.
- Vulkan and Metal share the same frame-level public API and lifetime semantics.
- Backend compile tests pass.

### Checkpoint D: After Phases 8-9

- CPU/GPU ABI and blob layout checks are explicit.
- Docs match the implemented architecture.
- Full release build and CI command set pass.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Moving blob ownership off `hb.Blob` exposes lifetime bugs | High | Land `CoverageBlob` with decoder and upload tests before changing renderer cache code |
| Regularization changes alter rendering output | High | Keep full-scan CPU reference tests and add known pathological cubic fixtures |
| `TextBatch` abstraction adds allocation or copies | Medium | Design it as a borrowed fixed-capacity writer over mapped memory |
| Backend frame lifetime diverges between Vulkan and Metal | High | Add fake backend frame tests and document frame-token semantics in one core module |
| Shader constants drift from Zig blob format | Medium | Add a generated check or a test that extracts both constant sets |
| Public root cleanup breaks examples | Medium | Update README and keep intentional aliases only |

## Parallelization Opportunities

- Phases 2 and 3 should be sequential because outline capture depends on the font API decision.
- Phase 8 shader layout validation can run in parallel with Phase 6 once `CoverageBlob` layout is stable.
- Documentation updates in Phase 9 can start after Checkpoint B, but final wording must wait until backend integration is complete.
- Backend Vulkan and Metal frame integration can be split between workers after the `TextBatch` contract is fixed.

## Resolved Questions

- `heavy_slug.core` and `heavy_slug.gpu` remain exported for expert/internal users; the stable root aliases remain the documented public path.
- `ShapePlan` currently exposes typed direction/script properties. HarfBuzz feature-string support remains additive future work.
- `CoverageBlob` owns `[]Texel` and exposes aligned bytes for upload.
- H-band dedupe for multi-band fragments remains out of scope until pixel-diff infrastructure exists; multi-band fragments still use full scan.
- `FontContext` was removed. `FontSystem`, `LoadedFont`, `GlyphEncoder`, and `ShapePlan` carry its former responsibilities.
