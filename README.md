# heavy-slug

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.4-ac162c)](https://www.vulkan.org/)
[![Metal](https://img.shields.io/badge/Metal-4-8f8f8f)](https://developer.apple.com/metal/)
[![Slang](https://img.shields.io/badge/Slang-2026-2d6cdf)](https://shader-slang.org/)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines through FreeType, encodes compact cubic coverage blobs, and draws
them with task, mesh, and fragment shaders on Vulkan 1.4 and Metal 4.

The project is inspired by the
[Slug algorithm](https://jcgt.org/published/0006/02/02/), but the implementation
is intentionally modern: cubic-native outline data, conservative GPU culling,
host-owned graphics lifetimes, generated GPU ABI structs, and shared Slang 2026
shader sources.

```text
UTF-8 text -> HarfBuzz shaping -> font outlines -> precision blobs -> GPU culling -> analytic coverage
```

| Design promise | Practical effect |
| --- | --- |
| Analytic text | No CPU glyph atlas or SDF reconstruction path. |
| Explicit ownership | Applications keep their windows, devices, queues, and frame pacing. |
| Opt-in backends | Core builds stay free of Vulkan, Metal, `slangc`, and window-system deps. |
| Shared shader model | Vulkan and Metal consume the same Slang source layout. |
| Stable zoom math | CPU f64 affine charts and tiered fixed-point blobs avoid GPU f32 cancellation. |

## Quick Start

| Goal | Command | Notes |
| --- | --- | --- |
| Core build | `zig build` | Builds the backend-neutral library. |
| Core tests | `zig build test` | No shader compiler or GPU SDK required. |
| Vulkan tests | `zig build test -Dvulkan=true` | Requires `slangc` and Vulkan packages. |
| Metal tests | `zig build test -Dmetal=true` | macOS only; requires Metal 4 SDK and `slangc`. |
| SPIR-V shaders | `zig build spirv` | Installs SPIR-V 1.6 outputs under `zig-out/`. |
| Metal shaders | `zig build msl` | Installs Metal shader outputs under `zig-out/`. |

<details>
<summary>Demo commands</summary>

```bash
zig build run -Ddemo=true -Ddemo-backend=vulkan
zig build run -Ddemo=true -Ddemo-backend=metal
```

`-Ddemo-backend=auto` selects Vulkan on Windows/Linux and Metal on macOS.

</details>

<details>
<summary>Useful verification commands</summary>

```bash
zig fmt --check build.zig build/ demo/ src/ tools/
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
zig build test -Ddemo=true -Ddemo-backend=vulkan
zig build test -Ddemo=true -Ddemo-backend=metal
```

</details>

## Contents

- [Why It Exists](#why-it-exists)
- [Architecture At A Glance](#architecture-at-a-glance)
- [Build Dependencies](#build-dependencies)
- [Public Modules](#public-modules)
- [Pipeline](#pipeline)
- [Backend Notes](#backend-notes)
- [Shader Layout](#shader-layout)
- [Diagnostics](#diagnostics)
- [Project Layout](#project-layout)
- [Implementation Notes](#implementation-notes)
- [Dependency Summary](#dependency-summary)
- [CI](#ci)
- [Credit](#credit)
- [License](#license)

## Why It Exists

High-quality text rendering is usually forced into one of three buckets: cached
bitmaps, signed-distance fields, or dense outline geometry. `heavy-slug` takes a
different route: keep outline coverage data compact, make the GPU reject work
that cannot affect a pixel, and evaluate coverage analytically at the end.

| Common path | Typical cost | `heavy-slug` path |
| --- | --- | --- |
| Raster atlas | Scale artifacts and atlas churn | Reusable outline blobs. |
| SDF/MSDF | Reconstruction artifacts | Direct analytic coverage. |
| Tessellated outlines | More geometry and MSAA pressure | Mesh/task culling plus fragment integration. |

The core library focuses on text preparation and cache ownership. It does not
try to be a windowing toolkit, application framework, or GPU device manager.

## Architecture At A Glance

```text
Application
  owns window / device / queue / swapchain / frame completion
      |
      v
Backend module: heavy_slug_vulkan or heavy_slug_metal
  owns GPU buffers, pipelines, and backend submission glue
      |
      v
Core module: heavy_slug
  shapes text, encodes glyphs, manages cache metadata, emits draw batches
      |
      v
Task -> Mesh -> Fragment shaders
  cull glyph work, emit compact meshlets, integrate analytic coverage
```

| Layer | Owns | Does not own |
| --- | --- | --- |
| `heavy_slug` | Fonts, shaping, outline encoding, cache metadata, backend-neutral batches. | GPU context, swapchain, command queue, window. |
| `heavy_slug_vulkan` | Vulkan buffers, pipeline state, frame binding, draw recording. | Instance, surface, swapchain, queue policy. |
| `heavy_slug_metal` | Metal bridge state, buffers, pipeline state, frame slots. | Cocoa app lifecycle. |
| Demo code | Native Win32, Wayland, Cocoa hosts, and shared scene/input helpers. | Library API policy. |

## Build Dependencies

| Area | Build requirements | Runtime/demo requirements |
| --- | --- | --- |
| Core | Zig `0.16.0`, C/C++ toolchain, pinned package fetch on first build. | None beyond the embedding application. |
| Shaders and backends | `slangc` with Slang 2026 support. | Backend-specific GPU runtime. |
| Vulkan backend | Lazy `vulkan-zig` and Vulkan Headers packages. | Vulkan 1.4, mesh shaders, dynamic rendering, push descriptors. |
| Windows Vulkan demo | Native Win32 host; links `user32`; loads the Vulkan loader at runtime. | Vulkan-capable Windows 11 system. |
| Linux Vulkan demo | `wayland-scanner`, `wayland-client`, `xkbcommon`, and xdg-shell/viewporter/fractional-scale protocol XML. | Modern Wayland session and Vulkan loader/driver. |
| Metal backend/demo | macOS, Apple SDK with Metal 4 APIs, Objective-C++ support, `Metal`, `QuartzCore`, `Foundation`, and `Cocoa` for the demo. | Metal 4 capable device and native Cocoa host. |

Important dependency facts:

- FreeType and HarfBuzz are pinned source dependencies in `build.zig.zon` and
  are built statically by the Zig build. Normal builds do not require system
  FreeType or HarfBuzz packages.
- Core-only `zig build` and `zig build test` do not require `slangc`, Vulkan,
  Metal, Wayland, Cocoa, or a window toolkit.
- Vulkan and Vulkan Headers stay lazy; they are fetched only when the Vulkan
  backend or Vulkan demo is requested.
- The demo hosts are deliberately native: Win32 on Windows, Wayland on Linux,
  and Cocoa on macOS. GLFW/SDL-style toolkit dependencies are not part of the
  current build model.
- Linux demo builds can override tool locations with `-Dwayland-scanner=` and
  `-Dwayland-protocols-dir=`.

## Public Modules

| Module | Enabled by | Purpose |
| --- | --- | --- |
| `heavy_slug` | default | Core public types and backend-neutral renderer logic. |
| `heavy_slug_vulkan` | `-Dvulkan=true` or Vulkan demo | Vulkan 1.4 / SPIR-V 1.6 backend. |
| `heavy_slug_metal` | `-Dmetal=true` or Metal demo | macOS Metal 4 backend. |

Stable top-level core exports include `FontHandle`, `FontSource`,
`FontOptions`, `TextRun`, `FrameToken`, `Color`, `Transform`, `Affine2D64`,
`FrameView2D`, `PrecisionPolicy`, `Viewport`, `FillRule`, and `ShaderStats`.

Backend modules expose `Context`, `Renderer`, `Frame`, `Target`,
`RendererOptions`, `FontHandle`, `FrameToken`, `Stats`, and
`shader_stats_enabled`. The Metal backend also exposes `Host`, the borrowed
`id<MTLDevice>` / `id<MTL4CommandQueue>` / `CAMetalLayer *` contract used by
the bridge.

<details>
<summary>Typical frame shape</summary>

```zig
const heavy_slug = @import("heavy_slug");

// After the selected backend renderer has been initialized by the host:

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{
    .size_px = 32,
});

const view = heavy_slug.FrameView2D.identity(width_px, height_px);
var frame = try renderer.beginFrame(view);
try frame.drawText(.{
    .font = font,
    .text = "Heavy Slug",
    .transform = heavy_slug.Transform.translation(80, 140),
    .color = heavy_slug.Color.white,
});

const token = try frame.submit(target); // backend-specific Target
renderer.markFrameComplete(token);
```

</details>

## Pipeline

```text
TextRun
  -> HarfBuzz shaping
  -> HarfBuzz outline draw callbacks
  -> cubic normalization and regularization
  -> precision-tiered CoverageBlob cache entry
  -> GlyphInstance batch
  -> backend frame submission
  -> task/mesh/fragment shaders
```

| Stage | Key invariant |
| --- | --- |
| Shaping | Unicode shaping is delegated to HarfBuzz. |
| Outline capture | Glyphs stay as outline data; there is no CPU raster pass. |
| Cubic encoding | Lines, quadratics, and cubics share one tiered fixed-point GPU representation. |
| Cache | Glyph blobs are reused through a backend-owned byte pool. |
| GPU culling | Work is rejected only when it is conservatively safe. |
| Fragment coverage | Coverage is integrated analytically from the encoded curves. |

## Backend Notes

| Backend | Resource model | Host responsibility |
| --- | --- | --- |
| Vulkan | One glyph blob buffer, one per-frame glyph instance buffer, optional stats buffer. | Provide Vulkan objects, command buffers, render targets, and completed frame tokens. |
| Metal | Bridge-owned buffers and Metal 4 pipeline resources. | Provide borrowed Metal device, command queue, layer, and app lifecycle. |

Frame lifetime is explicit. Backends return `FrameToken` values on submit, and
cached GPU storage is retired only after the host reports completed work.

The Vulkan backend intentionally uses byte-offset `GlyphBlobRef` values rather
than per-glyph descriptor slots. The Metal backend follows the Metal 4 command
and argument-table path exposed through the Objective-C++ bridge.

## Shader Layout

| Path | Role |
| --- | --- |
| `shaders/core/` | Shared ABI, coverage, h-band, chart mapping, and stats logic. |
| `shaders/backend_vulkan/` | Vulkan resource binding shim. |
| `shaders/backend_metal/` | Metal resource binding shim. |
| `shaders/entries/task.slang` | Task shader entry. |
| `shaders/entries/mesh.slang` | Mesh shader entry. |
| `shaders/entries/fragment.slang` | Fragment shader entry. |

Shader sources use explicit Slang 2026 modules. `build/shaders.zig` compiles
source-declared entry points to SPIR-V 1.6 for Vulkan and Metal Shading
Language for Metal. GPU ABI structs are generated from Slang reflection by
`tools/layout_gen.zig`.

<details>
<summary>Shader output paths</summary>

```text
zig-out/shaders/spirv/task.spv
zig-out/shaders/spirv/mesh.spv
zig-out/shaders/spirv/fragment.spv
zig-out/shaders/msl/task.metal
zig-out/shaders/msl/mesh.metal
zig-out/shaders/msl/fragment.metal
```

</details>

## Diagnostics

| Diagnostic source | Signals |
| --- | --- |
| CPU/backend debug stats | Shaping counts, cache hits/misses, precision insufficiency, uploads, retirements, pool state, backend binding work. |
| Shader stats opt-in | Visible glyphs, emitted mesh work, explicit mesh cull reasons, candidate-path usage, fallback scans, fragment pressure. |

Enable shader counters only when investigating GPU behavior:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
```

## Project Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public core module. |
| `src/core/` | Types, fonts, outlines, blob encoding, cache, renderer core. |
| `src/gpu/` | Backend-neutral GPU ABI markers, mesh limits, shader stats. |
| `src/backends/vulkan/` | Vulkan backend. |
| `src/backends/metal/` | Metal backend and Objective-C++ bridge. |
| `demo/` | Demo entry points, native platform hosts, shared scene/input code. |
| `src/c/` | Core C headers translated by build-system `addTranslateC()`. |
| `build/` | Modular Zig build graph. |
| `shaders/` | Slang shader modules and entries. |
| `tools/layout_gen.zig` | Slang reflection to Zig extern structs. |
| `assets/` | Repository test/demo assets. |

## Implementation Notes

| Area | Current design |
| --- | --- |
| Core boundary | Core is backend-neutral and window-system-free. |
| Host boundary | Applications own graphics/device/window lifetimes. |
| Frame math | Draw submission uses a CPU f64 affine `FrameView2D`; backends no longer accept f32 projection matrices. |
| Glyph resources | Cached glyph blobs live in a backend-owned byte pool. |
| Blob precision | Glyph blobs are 32-bit fixed-point and keyed by precision tier. |
| Blob references | `GlyphBlobRef` values are byte offsets. |
| GPU ABI | Layouts are generated from Slang reflection. |
| C bindings | C declarations are translated by the build graph, not by source-level `@cImport`. |

`RendererCore` is the shared spine behind both backends: it loads fonts, shapes
runs, encodes missing glyphs, maintains cache metadata, writes backend-specific
glyph instances, and coordinates deferred resource retirement.

## Dependency Summary

| Dependency | Source | Lazy |
| --- | --- | --- |
| FreeType | `build.zig.zon` source archive | No |
| HarfBuzz | `build.zig.zon` source archive | No |
| `vulkan-zig` | pinned Git dependency | Yes |
| Vulkan Headers | pinned Git dependency | Yes |
| Wayland client/protocols | system Linux demo dependency | No |

Generated local outputs use the usual Zig paths: `zig-out/`, `.zig-cache/`, and
`zig-pkg/`. They are not source artifacts and should not be committed.

## CI

GitHub Actions run formatting, core tests, backend tests, shader-stat variants,
and demo build tests across Ubuntu, macOS, and Windows runners. Workflow
dispatch can override Zig and Slang versions; the default Zig version is read
from `build.zig.zon`.

| Job family | Coverage |
| --- | --- |
| Lint | Zig formatting checks. |
| Test | Core, Vulkan, Metal, shader-stat variants, and native demo hosts. |

## Credit

`heavy-slug` would not exist without Slug. Slug established the practical value
of GPU-side analytic glyph coverage and compact outline data. This project
keeps that foundation while exploring native cubic coverage blobs, mesh/task
shader culling, generated GPU ABI, and explicit Vulkan 1.4 / Metal 4 backend
boundaries.

## License

MIT. See [LICENSE](LICENSE).
