# heavy-slug Architecture Refactor Spec

## Status

Implemented. See `docs/refactor-traceability.md` for the phase-by-phase implementation audit.

## Date

2026-05-15

## Official References

- Zig 0.16.0 release notes: https://ziglang.org/download/0.16.0/release-notes.html
- Zig 0.16.0 language reference: https://ziglang.org/documentation/0.16.0/
- Zig 0.16.0 standard library: https://ziglang.org/documentation/0.16.0/std/
- Slang documentation: https://shader-slang.org/docs/
- Slang Metal target notes: https://docs.shader-slang.org/en/latest/external/slang/docs/user-guide/a2-02-metal-target-specific.html
- Apple Objective-C guide: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/Introduction/Introduction.html
- Clang ARC semantics: https://clang.llvm.org/docs/AutomaticReferenceCounting.html
- HarfBuzz API documentation: https://harfbuzz.github.io/

## Current Source Facts

The repository currently has a working Zig 0.16 text renderer with a lightweight public root in `src/root.zig`, core implementation modules under `src/core/`, GPU resource declarations under `src/gpu/`, opt-in backend modules under `src/backends/vulkan/` and `src/backends/metal/`, demo-only code under `src/demo/{common,vulkan,metal}/`, Slang shaders in `shaders/`, and ABI generation in `tools/layout_gen.zig`.

The important existing decisions should remain: the core does not own a GPU context, GLFW is demo-only, Vulkan/Metal are opt-in, C imports are build-system generated through `addTranslateC()`, and CPU/GPU layouts are generated from Slang reflection instead of hand-written.

## Problem Statement

The project works, but repeated iteration has left several contracts implicit:

- The legacy renderer core owned too many responsibilities: shaping, glyph encoding, cache lookup, pool allocation, backend upload, and command generation.
- The backend contract is encoded by `anytype` methods rather than a named interface.
- Vulkan and Metal use different glyph reference meanings: Vulkan stores descriptor slots, while Metal stores byte offsets.
- GPU in-flight lifetime is not represented as a first-class type. Metal waits conservatively; Vulkan relies on less explicit reuse behavior.
- Coverage blob layout, h-band acceleration, and shader decode logic are tightly coupled across CPU and shader files.
- Slang source uses backend conditionals in core shader logic, which makes Metal/Vulkan behavior harder to reason about independently.
- `build.zig` combines dependency setup, shader compilation, backend wiring, demo wiring, and C library builds in one large file.

The refactor should make these boundaries explicit and let the implementation follow them.

## Goals

- Redesign public API around a small, hard-to-misuse renderer surface.
- Split private implementation into font, outline, blob, cache, frame, and backend layers.
- Make frame lifetime and deferred resource retirement explicit on both Vulkan and Metal.
- Keep exact analytic coverage as the correctness path; h-band indexing remains an optimization only.
- Make Slang ABI generation the only accepted CPU/GPU layout contract.
- Keep `glfw_src`, `vulkan`, and `vulkan_headers` lazy.
- Keep Objective-C++ behind a C ABI bridge so Zig never depends on C++ or Objective-C types directly.
- Improve tests so CPU reference math, blob decode, cache lifetime, and backend compile coverage are separately verified.

## Non-Goals

- No CPU rasterization fallback.
- No texture atlas path.
- No retained scene graph.
- No hidden GPU context creation in the core library.
- No source-level `@cImport`.
- No compatibility layer for old public APIs.

## Target Data Flow

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

Each arrow is an ownership and validation boundary. Data entering a boundary is either validated once or represented by a type that cannot be constructed incorrectly.

## Target Project Structure

```text
src/
  root.zig
  core/
    types.zig
    units.zig
    errors.zig
    font/
      freetype.zig
      harfbuzz.zig
      font_system.zig
      shape.zig
    outline/
      stream.zig
      regularize.zig
      area.zig
    blob/
      format.zig
      encode.zig
      decode.zig
      hband.zig
      reference.zig
    cache/
      glyph_cache.zig
      byte_pool.zig
      retirement.zig
    render/
      renderer_core.zig
      glyph_store.zig
      text_batch.zig
      backend_contract.zig
  gpu/
    abi.zig
    resource_model.zig
  backends/
    vulkan/
      root.zig
      context.zig
      frame.zig
      glyph_store.zig
      pipeline.zig
      descriptors.zig
      renderer.zig
    metal/
      root.zig
      bridge.h
      bridge.mm
      context.zig
      frame.zig
      glyph_store.zig
      renderer.zig
  demo/
    common/
      scene.zig
      glfw.zig
    vulkan/
      main.zig
      host.zig
    metal/
      main.zig
      host.h
      host.mm
build/
  deps.zig
  c_libs.zig
  shaders.zig
  backends.zig
  demos.zig
tools/
  layout_gen.zig
shaders/
  core/
  backend_vulkan/
  backend_metal/
  entries/
```

## Public API Contract

The root module should export only stable concepts:

```zig
pub const Color = core.types.Color;
pub const Transform = core.types.Transform;
pub const FontHandle = core.types.FontHandle;
pub const FontSource = core.font.FontSource;
pub const FontOptions = core.font.FontOptions;
pub const RendererOptions = core.render.RendererOptions;
pub const TextRun = core.render.TextRun;
pub const FillRule = core.types.FillRule;
```

Backend modules should expose a consistent shape:

```zig
pub const Context = ...;
pub const Renderer = ...;
pub const Frame = ...;
pub const Target = ...;
pub const Error = ...;
pub const required_features = ...;
```

Preferred usage:

```zig
var renderer = try heavy_slug_vulkan.Renderer.init(.{
    .context = vk_context,
    .target_format = color_format,
    .allocator = allocator,
    .options = .{},
});
defer renderer.deinit();

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{
    .size_px = 24,
});

var frame = try renderer.beginFrame(.{
    .projection = projection,
    .viewport = .{ .width = w, .height = h },
});
try frame.drawText(.{
    .font = font,
    .text = "Heavy Slug",
    .transform = .translation(100, 200),
    .color = .black,
});
try frame.submit(target);
```

The API deliberately separates `beginFrame`, `drawText`, and `submit`. Resource reuse and retirement belong to `Frame`, not to ad-hoc calls on the renderer.

## Private API Contract

`core/render/backend_contract.zig` should define the compile-time backend contract:

```zig
pub fn BackendContract(comptime B: type) void {
    comptime {
        assertDecl(B, "GlyphRef");
        assertDecl(B, "FrameToken");
        assertFn(B, "uploadBlob");
        assertFn(B, "retireBlob");
        assertFn(B, "writeCommands");
    }
}
```

`GlyphRef` must be opaque to the core. Vulkan may implement it as a descriptor index; Metal may implement it as a byte offset. The core may store and compare it, but must not interpret it.

## Core Data Types

- `Transform`: public 2D transform. Internally backed by PGA `Motor`, but the public name should describe the user concept.
- `Units`: explicit conversions among pixel space, HarfBuzz 26.6 positions, font units, quantized blob units, and screen pixel-local coordinates.
- `OutlineStream`: move, line, quadratic, cubic, close. This is the raw font outline contract.
- `RegularizedCubicSpan`: monotone, quantizable cubic segment plus bounds.
- `CoverageBlob`: owned byte payload with a fixed header and decode helpers.
- `GlyphKey`: font id, glyph id, face index, size, variation key, fill mode.
- `FrameToken`: backend-provided monotonic frame identity for deferred frees.
- `TextBatch`: append-only command writer for one frame.

## Coverage Blob Format

The format is `CoverageBlob`.

Required properties:

- Fixed header with little-endian integer fields.
- Section bases are derived from counts and fixed section order instead of stored as header fields.
- Separate sections: header, curve spans, h-band table, candidate ids.
- CPU decoder used by tests and debugging tools.
- Shader decoder generated or manually mirrored only from `format.zig` constants.
- H-band is not a correctness boundary. It may only reduce candidate curves.
- Multi-band fragments must fall back to full scan until dedupe is implemented and pixel-diff tested.

## Shader Architecture

Slang should be split by responsibility:

```text
shaders/core/
  abi.slang
  pga.slang
  coverage_blob.slang
  coverage_integral.slang
  hband.slang
shaders/backend_vulkan/
  resources.slang
shaders/backend_metal/
  resources.slang
shaders/entries/
  slug_task.slang
  slug_mesh.slang
  slug_fragment.slang
```

Backend conditionals should exist only in resource binding shims or entry wrappers. Coverage math should be backend-neutral.

## Objective-C++ Boundary

Metal should keep a `.mm` implementation behind `bridge.h`.

Rules:

- Zig passes and receives only C ABI handles.
- The bridge owns retained Objective-C objects only when the C API says so.
- Host-provided `id<MTLDevice>`, `id<MTLCommandQueue>`, and `CAMetalLayer *` are borrowed unless the function name says `retain`.
- All Metal errors cross the C boundary as structured status plus error text.
- Frame slots, command buffers, drawable acquisition, and completion handlers belong to the bridge.
- Demo Cocoa/GLFW window setup remains in `src/demo/metal/`.

## Build System

`build.zig` should become orchestration only. Helper modules in `build/` should own:

- dependency resolution and lazy dependencies;
- FreeType/HarfBuzz static builds;
- translate-C module creation;
- Slang shader compilation;
- reflection-driven ABI generation;
- backend module creation;
- demo executables.

ThinLTO behavior remains explicit with `-Dthinlto=auto|on|off`. Native macOS Mach-O limitations must remain encoded as build-time behavior rather than hidden CI knowledge.

## Test Strategy

Core tests:

- Unit conversion round trips.
- HarfBuzz shaping with repo asset fonts.
- Outline stream capture for line, quadratic, and cubic callbacks.
- Cubic regularization invariants.
- Blob encode/decode round trip.
- H-band candidate set is a superset of full-scan contributors.
- CPU reference coverage for generated edge cases.
- Cache promotion, eviction, and deferred retirement.

Backend tests:

- ABI layout tests from Slang reflection.
- Vulkan backend compile tests with generated SPIR-V.
- Metal backend compile tests with generated MSL on macOS.
- Renderer contract tests using a fake backend.

Demo tests:

- Shared scene projection keeps initial text orientation correct.
- Vulkan and Metal demos use the same content model.

## Phase Plan

### Phase 0: Baseline and Guardrails

**Description:** Freeze current behavior with build, shader, and CPU reference checks before moving files.

**Acceptance criteria:**

- Current `zig build test`, `zig build test -Dvulkan=true`, and `zig build test -Dmetal=true` pass on supported hosts.
- Current shader build commands still pass: `zig build shaders` and `zig build metal-shaders`.
- Current public API examples are captured as migration input, not compatibility requirements.

**Verification:**

- `zig fmt --check build.zig src/ tools/`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- `zig build shaders`
- `zig build metal-shaders`

**Files likely touched:** none, except temporary notes if needed.

**Dependencies:** none.

### Phase 1: Types, Units, and Public API Skeleton

**Description:** Add the new public vocabulary while keeping implementation stubs thin.

**Acceptance criteria:**

- `Color`, `Transform`, `Viewport`, `Projection`, `FontSource`, `FontOptions`, `RendererOptions`, and `FontHandle` live under `src/core/`.
- Public root exports only intentional stable types.
- PGA `Motor` becomes a private implementation detail behind `Transform`.
- Unit conversion helpers are centralized and tested.

**Verification:**

- `zig build test`
- New unit tests for pixel, 26.6, quantized blob, and projection conversions.

**Files likely touched:**

- `src/root.zig`
- `src/core/types.zig`
- `src/core/units.zig`
- `src/core/errors.zig`
- `src/math/pga.zig`

**Dependencies:** Phase 0.

### Phase 2: Font and Outline Pipeline Split

**Description:** Split FreeType/HarfBuzz loading, shaping, raw outline capture, and regularization into separate modules.

**Acceptance criteria:**

- Font loading and shaping are independent of blob encoding.
- `OutlineStream` records move, line, quadratic, cubic, and close commands.
- Regularization transforms raw outline commands into monotone cubic spans.
- Variation key plumbing exists in `GlyphKey`, even if variation axis API remains minimal.

**Verification:**

- `zig build test`
- Tests prove HarfBuzz callbacks capture native cubic curves from the repo OTF asset.
- Tests prove line and quadratic outlines are raised into cubic spans.

**Files likely touched:**

- `src/core/font/*`
- `src/core/outline/*`

**Dependencies:** Phase 1.

### Phase 3: CoverageBlob and CPU Reference Path

**Description:** Move blob format ownership into `src/core/blob/` and make CPU decode/reference coverage authoritative for tests.

**Acceptance criteria:**

- `CoverageBlob` has explicit header and section definitions.
- Encoder and decoder share constants from one Zig module.
- H-band candidate lookup is tested against full-scan reference behavior.
- Existing shader blob constants are treated as generated or mirrored from the Zig format.

**Verification:**

- `zig build test`
- Property-style generated tests for pathological cubic spans: flat, vertical, near-cusp, loop-split, high zoom, and boundary-touching cases.

**Files likely touched:**

- `src/core/blob/*`
- `src/core/outline/encode.zig`
- `shaders/core/coverage_blob.slang`

**Dependencies:** Phase 2.

### Phase 4: Renderer Core and Backend Contract

**Description:** Replace the legacy renderer core plus implicit `anytype` calls with an explicit renderer core and backend contract.

**Acceptance criteria:**

- `GlyphRef` is backend-opaque.
- `FrameToken` is mandatory for deferred retirement.
- `GlyphStore` owns cache metadata, byte-pool allocations, and pending frees.
- `TextBatch` owns command generation for one frame.
- Fake backend tests cover upload, cache hit, eviction, empty glyph, and frame retirement.

**Verification:**

- `zig build test`
- Contract tests fail at compile time if a backend misses required declarations.

**Files likely touched:**

- `src/core/render/*`
- `src/core/cache/*`
- `src/core/render/*`
- `src/gpu/resource_model.zig`

**Dependencies:** Phase 3.

### Phase 5: Shader Module Split and ABI Regeneration

**Description:** Reorganize Slang modules so coverage logic is backend-neutral and resource bindings are backend-specific.

**Acceptance criteria:**

- Backend conditionals are removed from core coverage math.
- Vulkan and Metal resource bindings live in separate shim modules.
- `tools/layout_gen.zig` still generates all CPU ABI structs from Slang reflection.
- SPIR-V 1.6 and Metal 4 shader builds pass.

**Verification:**

- `zig build shaders`
- `zig build metal-shaders`
- `zig build test`
- ABI size and offset tests for every generated struct.

**Files likely touched:**

- `shaders/*`
- `tools/layout_gen.zig`
- `src/gpu/abi.zig`
- `build/shaders.zig`

**Dependencies:** Phase 4.

### Phase 6: Vulkan Backend Rewrite

**Description:** Rebuild Vulkan around explicit frame slots, opaque glyph refs, and deferred frees.

**Acceptance criteria:**

- Vulkan renderer implements the backend contract.
- Command storage is per-frame or otherwise protected by explicit frame completion.
- Descriptor slot retirement is deferred until the backend reports the frame token complete.
- Public API matches the new `Renderer`, `Frame`, and `Target` shape.

**Verification:**

- `zig build test -Dvulkan=true`
- `zig build -Doptimize=ReleaseFast -Dvulkan=true`
- Demo manual check on a Vulkan mesh-shader device.

**Files likely touched:**

- `src/backends/vulkan/*`
- `src/demo/vulkan/*`

**Dependencies:** Phase 5.

### Phase 7: Metal Backend and Objective-C++ Bridge Rewrite

**Description:** Rebuild Metal around a clear C ABI bridge, frame slots, borrowed host objects, and Metal 4 mesh pipeline setup.

**Acceptance criteria:**

- Metal renderer implements the same backend contract as Vulkan.
- Objective-C++ bridge exposes typed C handles for context, pipeline, buffer, frame, and target.
- ARC ownership behavior is documented in `bridge.h`.
- Frame completion drives deferred retirement without unconditional full GPU waits on normal frames.
- Demo Cocoa/GLFW host remains outside the library backend.

**Verification:**

- `zig build test -Dmetal=true`
- `zig build metal-shaders`
- `zig build -Doptimize=ReleaseFast -Dmetal=true`
- `zig build run -Ddemo=true -Ddemo-backend=metal4` manual render check.

**Files likely touched:**

- `src/backends/metal/*`
- `src/demo/metal/*`

**Dependencies:** Phase 5.

### Phase 8: Build System Decomposition

**Description:** Move build helpers into `build/` modules and leave root `build.zig` as orchestration.

**Acceptance criteria:**

- Lazy dependencies remain lazy.
- C translation modules are still created by build steps, not source-level imports.
- Shader steps are reusable by tests, backend modules, and install steps.
- CI commands remain unchanged unless intentionally updated.

**Verification:**

- `zig build`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- `zig build shaders`
- `zig build metal-shaders`
- `zig build -Doptimize=ReleaseFast`

**Files likely touched:**

- `build.zig`
- `build/*.zig`

**Dependencies:** Phases 5, 6, and 7 can proceed before or alongside this, but final cleanup should happen after backend contracts settle.

### Phase 9: Demo Unification and Documentation

**Description:** Make Vulkan and Metal demos consume the same scene and renderer-facing API.

**Acceptance criteria:**

- Shared demo scene owns text content, projection, input semantics, and colors.
- Backend demos differ only in window/GPU host setup and target submission.
- README examples reflect the new API.
- AGENTS.md reflects the new structure.
- CHANGELOG.md records the breaking changes.

**Verification:**

- `zig build test`
- `zig build run -Ddemo=true -Ddemo-backend=metal4`
- Vulkan demo manual check where hardware is available.

**Files likely touched:**

- `src/demo/common/*`
- `src/demo/vulkan/*`
- `src/demo/metal/*`
- `README.md`
- `AGENTS.md`
- `CHANGELOG.md`

**Dependencies:** Phases 6 and 7.

### Phase 10: Final Cleanup and Quality Gate

**Description:** Remove old modules, aliases, compatibility shims, and dead documentation.

**Acceptance criteria:**

- No old backend or core compatibility roots remain unless intentionally exported as root aliases.
- Public exports are minimal and documented.
- No source-level `@cImport`.
- No generated artifacts are committed.
- No `.DS_Store` or editor metadata is tracked.

**Verification:**

- `zig fmt --check build.zig build/ src/ tools/`
- `zig build test`
- `zig build test -Dvulkan=true`
- `zig build test -Dmetal=true`
- `zig build shaders`
- `zig build metal-shaders`
- `zig build -Doptimize=ReleaseFast`
- `git diff --check`

**Dependencies:** all prior phases.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Coverage regressions during blob/shader split | High | CPU reference decoder, h-band vs full-scan tests, shader ABI layout tests |
| GPU lifetime bugs after frame-ring rewrite | High | Explicit `FrameToken`, deferred retirement queue, fake backend tests |
| Metal bridge ownership mistakes | High | C ABI ownership annotations, ARC bridge tests by construction, minimal borrowed-object API |
| Build refactor churn | Medium | Decompose after backend contracts stabilize, keep commands unchanged |
| Slang reflection shape changes | Medium | Keep `layout_gen.zig` tests with realistic reflection samples |
| API over-abstraction | Medium | Export only user-facing types; keep private modules private |

## Checkpoints

- **Checkpoint A:** Phases 1-3 complete. Core font, outline, blob, and reference coverage are independent and fully tested.
- **Checkpoint B:** Phases 4-5 complete. Renderer core and shaders compile against explicit backend contracts.
- **Checkpoint C:** Phases 6-7 complete. Vulkan and Metal both render through the same high-level API.
- **Checkpoint D:** Phases 8-10 complete. Build, docs, demos, and cleanup are ready for release.

## Open Questions

- Whether `Transform` should expose only rigid transforms or also affine transforms. Current PGA path is rigid; broader affine support would change shader math.
- Whether `CoverageBlob` should keep 16-bit quantized texels or move to mixed 16/32-bit sections. Keep 16-bit unless CPU reference tests prove it causes unavoidable artifacts.
- Whether h-band dedupe should be implemented in the first rewrite or left as a post-correctness optimization. Default answer: leave it post-correctness.
