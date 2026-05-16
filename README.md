# heavy-slug

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode text with HarfBuzz, extracts
native glyph outlines, encodes them into compact cubic coverage blobs, and
renders them with task, mesh, and fragment shaders on Vulkan 1.4 and Metal 4.

The project is inspired by and explicitly credits the
[Slug algorithm](https://jcgt.org/published/0006/02/02/): Slug showed that
high-quality text can be rendered by evaluating vector outline coverage on the
GPU instead of uploading rasterized glyph atlases. `heavy-slug` keeps that
central idea, but rebuilds the pipeline around native cubic analytics,
mesh/task shader culling, and a shared Slang shader codebase for modern Vulkan
and Metal.

## Algorithmic Breakthroughs

### Native Cubic Analytics

Many GPU text renderers reduce outlines to triangles, signed-distance fields, or
atlas texels. `heavy-slug` keeps the analytic outline alive all the way to the
fragment shader.

- TrueType quadratic curves and CFF/CFF2 cubic curves are captured through
  HarfBuzz draw callbacks.
- Lines and quadratics are raised to cubic form so every backend consumes one
  curve representation.
- Cubics are split at axis extrema and inflection points, then regularized so
  quantized control polygons remain stable for GPU evaluation.
- The fragment shader solves cubic crossings with safeguarded Newton/bisection
  and applies Green's theorem by integrating clipped `x dy` coverage directly
  in pixel-local coordinates.
- Fill resolution supports non-zero and even-odd rules without CPU rasterization
  or glyph atlas updates.

This is the main algorithmic break from the original Slug data path: the
implementation is cubic-native rather than quadratic-oriented. That matters for
CFF and CFF2 fonts because their outlines are cubic by construction, so the
renderer does not have to approximate native cubics through a lower-order
intermediate representation before evaluating coverage.

### Mesh/Task Shader Culling

The renderer treats mesh/task shaders as a text-specific work amplifier, not as
a compatibility replacement for old vertex processing.

- The task shader rejects invisible glyph boxes before mesh work is launched.
- Surviving glyphs are subdivided into horizontal h-band meshlets.
- The mesh shader scans each meshlet's band-local curve candidates and emits
  only non-empty tightened strips.
- Fragment work starts from cleaner screen-space regions, so the analytic
  fragment shader spends less time proving empty pixels are empty.
- Shader counters expose the important ratios: visible task glyphs, emitted
  mesh tiles, mesh-tile culls, fragments per tile, candidate-path fragments, and
  full-scan fallback fragments.

The h-band index is an acceleration structure, not a correctness shortcut. If a
fragment cannot be evaluated from a compact candidate band range, it falls back
to scanning all curves for that glyph. The mathematical contract is conservative:
Task and mesh stages may shrink the set of fragments, but only after proving the
discarded region cannot intersect any curve-expanded coverage support.

### Modern Backend Model

The core library owns text shaping, outline encoding, cache metadata, and
backend-neutral command generation. Applications still own GPU devices, queues,
swapchains, windows, and frame completion.

- Vulkan uses SPIR-V 1.6 mesh shaders on Vulkan 1.4 with `VK_EXT_mesh_shader`.
  Glyph blobs live in one storage buffer and `glyph_ref` is a byte offset.
  Per-glyph descriptor slots were removed because the single-pool model is
  simpler and faster for the current data layout.
- Metal uses the Metal 4 core API: `MTL4CommandQueue`,
  `MTL4CommandAllocator`, `MTL4Compiler`, `MTL4MeshRenderPipelineDescriptor`,
  and `MTL4ArgumentTable`.
- The shared shader source is written in Slang and split into reusable core
  modules plus backend binding shims.

## Pipeline Overview

```text
FontSystem
  -> ShapePlan
  -> OutlineStream
  -> RegularizedCubicSpans
  -> CoverageBlob
  -> GlyphStore
  -> TextBatch
  -> Backend Frame
  -> Task/Mesh/Fragment shaders
```

`FontSystem` owns FreeType and HarfBuzz lifetime. `ShapePlan` shapes UTF-8 text
into glyph IDs and advances. `OutlineStream` captures the glyph path. The
encoder converts every segment to a cubic span, regularizes the spans, and
writes a compact `CoverageBlob` containing:

- glyph bounds,
- cubic control points,
- curve bounds,
- h-band metadata,
- packed band candidate curve IDs.

`GlyphStore` owns the two-tier glyph cache, byte-pool allocations, and deferred
resource retirement. The renderer core emits backend-neutral `GlyphCommand`
records into a `TextBatch`. Backends upload the command buffer, bind the shared
glyph pool, and submit one task/mesh draw. Resource reuse is guarded by
`FrameToken` completion reported by the host.

## Algorithm Details

1. **Shape text.** HarfBuzz maps Unicode text to positioned glyphs using the
   caller's font and options.
2. **Capture outlines.** HarfBuzz draw callbacks emit move, line, quadratic,
   and cubic path commands without asking FreeType to rasterize.
3. **Normalize to cubics.** Lines and quadratics are raised to cubic form.
   Native CFF/CFF2 cubics stay cubic.
4. **Regularize.** The CPU splits cubics at derivative roots and inflections,
   then subdivides spans until the quantized control polygon is monotone enough
   for stable shader evaluation.
5. **Encode coverage blobs.** The blob stores cubic data plus an h-band
   candidate index. Blob texels use compact integer units and are decoded by
   shared Slang code.
6. **Cull in task shader.** A task workgroup evaluates glyph visibility and
   compacts visible h-band meshlets into task payload memory.
7. **Tighten in mesh shader.** Each mesh workgroup scans band-local curve
   bounds, reduces the X range, and emits a small strip only when the meshlet
   can contribute coverage.
8. **Integrate in fragment shader.** The fragment shader maps the pixel into
   glyph-local coordinates, finds candidate curves, solves crossings, integrates
   cubic area, and resolves the fill rule.

The important invariant is conservative filtering: task culling, h-band
subdivision, and mesh strip tightening may reduce work only when they preserve
all fragments that can affect coverage.

## Project Layout

```text
src/root.zig             core public module
src/core/                public types plus font, outline, blob, cache, render internals
src/gpu/                 backend-neutral GPU ABI, mesh limits, shader stats
src/math/                PGA motor math
src/backends/vulkan/     Vulkan 1.4 mesh-shader backend
src/backends/metal/      Metal 4 backend and Objective-C++ bridge
src/demo/common/         shared demo scene/input code
src/demo/vulkan/         Vulkan demo host
src/demo/metal/          Metal 4 demo host
src/c/                   headers translated by build-system addTranslateC()
build/                   modular Zig build graph
shaders/core/            shared Slang ABI, PGA, coverage, h-band modules
shaders/backend_*        backend resource binding shims
shaders/entries/         task, mesh, and fragment entry points
tools/layout_gen.zig     Slang reflection to Zig extern structs
assets/                  test and demo assets
```

## Requirements

- Zig 0.16.0.
- `slangc` on `PATH` for shader build steps and demos.
- Vulkan backend: Vulkan 1.4 plus `VK_EXT_mesh_shader`.
- Metal backend: macOS with Metal 4 mesh-shader support. Host code must provide
  an `id<MTLDevice>`, `id<MTL4CommandQueue>`, and `CAMetalLayer *`.

Third-party source dependencies are pinned in `build.zig.zon`. `vulkan`,
`vulkan_headers`, and `glfw_src` are lazy dependencies, so normal core builds do
not fetch backend-only or demo-only packages.

## Build And Test

```bash
zig build
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build test -Dvulkan=true -Dmetal=true -Dshader-stats=true
zig build shaders
zig build metal-shaders
zig build -Doptimize=ReleaseFast
```

Useful options:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
zig build shaders -Dshader-stats=true
zig build metal-shaders -Dshader-stats=true
zig build -Dthinlto=auto
zig build -Dthinlto=on
zig build -Dthinlto=off
```

`-Dshader-stats=true` enables opt-in GPU counter buffers for performance
diagnostics. It is off by default so normal debug and release builds avoid
shader atomics and the extra stats binding.

`-Dthinlto=auto` is the default. Zig 0.16 requires LLD for LTO; native macOS
Mach-O LLD linking is unsupported, so macOS release builds skip ThinLTO unless
`-Dthinlto=on` is used to require a hard failure.

## Demos

```bash
zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16
zig build run -Ddemo=true -Ddemo-backend=metal4
```

The Vulkan demo is intended for Windows/Linux. The Metal demo is intended for
macOS and creates a GLFW Cocoa window in demo-only code.

## Basic Usage

Import the core module plus one backend module. The host owns GPU objects and
frame synchronization.

```zig
const heavy_slug = @import("heavy_slug");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");

try heavy_slug_vulkan.Context.checkDeviceSupport(
    physical_device,
    instance_dispatch,
    allocator,
);

const ctx = heavy_slug_vulkan.Context.init(
    physical_device,
    device,
    instance_dispatch,
    get_device_proc_addr,
);

var renderer = try heavy_slug_vulkan.Renderer.init(ctx, color_format, allocator, .{});
defer renderer.deinit();

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{
    .size_px = 24,
});

var frame = try renderer.beginFrame();
try frame.drawText(.{
    .font = font,
    .text = "Hello, world!",
    .transform = heavy_slug.Transform.translation(100, 200),
    .color = .white,
});

const token = try frame.submit(.{
    .command_buffer = cmd_buf,
    .projection = projection,
    .viewport = .{ viewport_w, viewport_h },
});

renderer.markFrameComplete(token);
```

Metal follows the same renderer shape, but the context is initialized from
host-owned Objective-C objects. The command queue must be an
`id<MTL4CommandQueue>`.

```zig
const heavy_slug_metal = @import("heavy_slug_metal");

var ctx = try heavy_slug_metal.Context.init(.{
    .device = mtl_device,
    .command_queue = mtl4_queue,
    .layer = metal_layer,
});
defer ctx.deinit();

var renderer = try heavy_slug_metal.Renderer.init(ctx, allocator, .{});
defer renderer.deinit();
```

## Backend Notes

### Vulkan

The Vulkan backend uses conventional descriptor sets for the small frame-local
binding table:

- binding 0: one glyph blob storage buffer,
- binding 1: frame-local `GlyphCommand[]`,
- binding 2: optional shader stats buffer.

`VK_EXT_descriptor_heap` was evaluated but not adopted. The renderer no longer
needs a descriptor per cached glyph; a single glyph pool buffer with byte-offset
`GlyphRef` values removes the pressure that descriptor heap would have solved.

### Metal 4

The Metal backend uses the Metal 4 core API path:

- host supplies `id<MTL4CommandQueue>`,
- each frame slot owns an `MTL4CommandAllocator`,
- shaders and the mesh pipeline are built through `MTL4Compiler`,
- resource bindings are snapshots from a per-frame `MTL4ArgumentTable`,
- command submission uses `MTL4CommandQueue.commit`.

The Objective-C++ bridge is intentionally small: Zig owns renderer state, while
the bridge owns only Objective-C object lifetime and API calls that cannot be
expressed directly from Zig.

## Diagnostics

Debug builds expose backend `Stats` snapshots with shaping counts, cache
hit/miss counts, encoded outline/span counts, uploaded blob bytes, pool
fragmentation, deferred retirements, descriptor writes, frame-slot waits, and
optional shader counters.

Use shader counters only when investigating performance:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
```

The most useful GPU ratios are:

- task-visible glyphs versus tested glyphs,
- emitted mesh tiles versus mesh workgroups,
- mesh tiles culled,
- fragments per visible glyph,
- fragments per mesh tile,
- candidate-path fragments versus full-scan fragments,
- candidate curve tests versus full-scan curve tests,
- bbox-rejected and zero-coverage fragments.

High full-scan counts usually mean the transform or glyph geometry spans too
many h-bands for the compact candidate path. High fragments-per-tile counts
usually mean meshlet strip tightening is not isolating enough empty screen
space.

## Design Principles

- Preserve analytic coverage until the fragment shader.
- Prefer conservative culling over approximate culling.
- Keep the core renderer backend-neutral.
- Keep GPU context and frame ownership in host applications.
- Generate GPU ABI structs from Slang reflection, never by hand.
- Treat README as the canonical architecture and algorithm overview.

## Credit

`heavy-slug` would not exist without the ideas in Slug. The original Slug work
established the practical value of GPU-side analytic glyph coverage and compact
outline data. This project is a modern, cubic-native, mesh/task-shader
implementation that credits Slug as the foundation while exploring a different
engineering path for contemporary graphics APIs.

## CI

GitHub Actions run formatting on `ubuntu-latest`, tests on `ubuntu-latest` and
`macos-26`, backend-specific test variants, shader-stats test variants, and
ReleaseFast builds. Workflow dispatch can override Zig and Slang versions.

## License

MIT. See [LICENSE](LICENSE).
