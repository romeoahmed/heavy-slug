# heavy-slug

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic, resolution-independent text. It shapes Unicode text with HarfBuzz, captures native glyph outlines, encodes them into compact cubic coverage blobs, and submits backend-neutral glyph commands to opt-in Vulkan and Metal mesh-shader renderers.

The project is inspired by and credits the [Slug algorithm](https://jcgt.org/published/0006/02/02/) for the central idea of evaluating vector outline coverage directly on the GPU instead of rasterizing glyphs into texture atlases. The current implementation keeps that spirit, but uses a cubic-native coverage pipeline rather than the original quadratic-oriented data path.

## Goals

- Keep the core library small: fonts, shaping, outline encoding, cache/pool management, and backend-neutral command generation.
- Keep GPU ownership external: applications provide Vulkan or Metal objects; `heavy-slug` does not create devices or windows.
- Keep GLFW demo-only: no core or backend module depends on GLFW.
- Render TrueType and CFF/CFF2 outlines without CPU rasterization or atlas uploads.
- Share one Slang shader codebase across Vulkan SPIR-V 1.6 and macOS Metal 4.

## Architecture

The runtime pipeline is:

```text
FontSystem
  -> ShapePlan
  -> OutlineStream
  -> RegularizedCubicSpans
  -> CoverageBlob
  -> GlyphStore
  -> TextBatch
  -> Backend Frame
  -> GPU submit
```

`FontSystem` owns FreeType and HarfBuzz lifetime. `ShapePlan` reuses HarfBuzz buffers for text shaping. Glyph outlines are captured through HarfBuzz draw callbacks as move, line, quadratic, and cubic segments. The encoder normalizes all segments to cubic spans, regularizes them, and writes a backend-neutral `CoverageBlob`.

`GlyphStore` owns the two-tier glyph cache, byte pool, and deferred resource retirement. The renderer core turns shaped glyphs into `TextBatch` commands with `GlyphRef` handles. Backend frames upload commands and bind blob storage, but resource reuse is guarded by `FrameToken` completion reported by the host.

Backends are separate modules:

- `heavy_slug_vulkan`: Vulkan SPIR-V 1.6 mesh-shader backend for Windows/Linux.
- `heavy_slug_metal`: macOS Metal 4 backend using Slang-generated MSL and an Objective-C++ bridge.

## Algorithm

1. FreeType loads font faces and HarfBuzz shapes text into glyph IDs and advances.
2. HarfBuzz outline callbacks emit native outline segments. TrueType quadratic curves and CFF/CFF2 cubic curves are preserved at capture time; lines and quadratics are raised to cubic form for one common representation.
3. Cubics are split at x/y derivative roots and inflection roots. The CPU encoder then recursively subdivides spans until the quantized control polygon remains monotone enough for stable GPU evaluation.
4. The encoder writes `CoverageBlob` texels: header, cubic control points, and an h-band candidate index. The h-band only filters likely curves; correctness still comes from the full analytic path.
5. The mesh path emits one glyph quad. The fragment shader transforms each cubic into pixel-local coordinates, splits it into monotone intervals, solves cubic crossings with safeguarded Newton/bisection, and integrates clipped `x dy` coverage with a small Gauss rule.
6. Fill is resolved with non-zero or even-odd rules. If a fragment cannot use a single h-band candidate range, it falls back to full curve scanning.

This is still related to Slug at the architectural level: GPU-side analytic outline coverage, compact glyph blobs, and mesh/fragment evaluation. It differs in the details: native cubic support, a custom blob format, CPU-side regularization, h-band candidate filtering, and shared Vulkan/Metal Slang backends.

## Project Layout

```text
src/root.zig             core public module
src/core/                public types plus font, outline, blob, cache, and render internals
src/gpu/                 backend-neutral GPU ABI and diagnostics types
src/math/                PGA motor math
src/backends/vulkan/     Vulkan backend module
src/backends/metal/      Metal backend module and ObjC++ bridge
src/demo/common/         shared demo scene/input code
src/demo/vulkan/         Vulkan demo host
src/demo/metal/          Metal demo host
src/c/                   headers translated by build-system addTranslateC()
build/                   modular Zig build graph
shaders/core/            shared Slang ABI, PGA, coverage, and h-band modules
shaders/backend_*        backend resource binding shims
shaders/entries/         task, mesh, and fragment entry points
tools/layout_gen.zig     Slang reflection to Zig extern structs
assets/                  test and demo assets
```

## Requirements

- Zig 0.16.0.
- `slangc` on `PATH` for shader build steps and demos.
- Vulkan backend: Vulkan 1.4, `VK_EXT_mesh_shader`, and `VK_EXT_robustness2`.
- Metal backend: macOS with Metal 4 mesh-shader support.

Third-party source dependencies are pinned in `build.zig.zon`. `vulkan`, `vulkan_headers`, and `glfw_src` are lazy dependencies, so normal core builds do not fetch backend-only or demo-only packages.

## Build And Test

```bash
zig build
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build shaders
zig build metal-shaders
zig build -Doptimize=ReleaseFast
```

Useful options:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
zig build -Dthinlto=auto
zig build -Dthinlto=on
zig build -Dthinlto=off
```

`-Dshader-stats=true` enables opt-in GPU counter buffers for fragment diagnostics such as candidate-vs-full-scan usage and curve-test counts. It is off by default so normal debug and release builds do not pay for shader atomics or extra bindings.

`-Dthinlto=auto` is the default. Zig 0.16 requires LLD for LTO; native macOS Mach-O LLD linking is unsupported, so macOS release builds skip ThinLTO unless `-Dthinlto=on` is used to require a hard failure.

## Demos

```bash
zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16
zig build run -Ddemo=true -Ddemo-backend=metal4
```

The Vulkan demo is intended for Windows/Linux. The Metal demo is intended for macOS and creates a GLFW Cocoa window in demo-only code.

## Basic Usage

Import the core module plus one backend module. The host owns GPU objects and frame synchronization.

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

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{ .size_px = 24 });

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

Metal follows the same renderer shape, but the context is initialized from host-owned Objective-C objects:

```zig
const heavy_slug_metal = @import("heavy_slug_metal");

var ctx = try heavy_slug_metal.Context.init(.{
    .device = mtl_device,
    .command_queue = mtl_queue,
    .layer = metal_layer,
});
defer ctx.deinit();

var renderer = try heavy_slug_metal.Renderer.init(ctx, allocator, .{});
defer renderer.deinit();
```

## Diagnostics

Debug builds expose backend `Stats` snapshots with shaping counts, cache hit/miss counts, encoded outline/span counts, uploaded blob bytes, pool fragmentation, deferred retirements, descriptor writes, frame-slot waits, and optional shader counters.

Use shader counters only when investigating performance:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
```

The most useful GPU ratios are candidate-path fragments versus full-scan fragments, and candidate curve tests versus full-scan curve tests. High full-scan counts usually mean the h-band filter is not isolating fragments well for the current transform or glyph geometry.

## CI

GitHub Actions run formatting on `ubuntu-latest`, tests on `ubuntu-latest` and `macos-26`, backend-specific test variants, shader-stats test variants, and ReleaseFast builds. Workflow dispatch can override Zig and Slang versions.

## License

MIT. See [LICENSE](LICENSE).
