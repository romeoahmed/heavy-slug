# heavy-slug

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.4-ac162c)](https://www.vulkan.org/)
[![Metal](https://img.shields.io/badge/Metal-4-8f8f8f)](https://developer.apple.com/metal/)
[![Slang](https://img.shields.io/badge/Slang-2026-2d6cdf)](https://shader-slang.org/)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines through FreeType, encodes compact cubic coverage blobs, expands
visible strips into a CPU-authored meshlet stream, and draws them with mesh and
fragment shaders on Vulkan 1.4 and Metal 4.

The project is inspired by the
[Slug algorithm](https://jcgt.org/published/0006/02/02/), but the implementation
is intentionally modern: cubic-native outline data, conservative GPU culling,
host-owned graphics lifetimes, generated GPU ABI structs, and shared Slang 2026
shader sources.

```text
UTF-8 text -> HarfBuzz shaping -> font outlines -> precision blobs -> CPU meshlets -> analytic coverage
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
| Core build | `zig build` | Builds and installs the backend-neutral static library under `zig-out/`. |
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
zig build swift-format-lint
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
| Tessellated outlines | More geometry and MSAA pressure | CPU meshlets plus mesh clipping and fragment integration. |

The core library focuses on text preparation and cache ownership. It does not
try to be a windowing toolkit, application framework, or GPU device manager.

## Architecture At A Glance

```text
Application
  owns window / device / queue / swapchain / frame completion
      |
      v
Backend module: heavy_slug_vulkan or heavy_slug_metal
  owns GPU buffers, shader/pipeline state, and backend submission glue
      |
      v
Core module: heavy_slug
  shapes text, encodes glyphs, manages cache metadata, emits draw batches
      |
      v
CPU meshlets -> Mesh -> Fragment shaders
  emit compact strips, clip meshlets, integrate analytic coverage
```

| Layer | Owns | Does not own |
| --- | --- | --- |
| `heavy_slug` | Fonts, shaping, outline encoding, cache metadata, backend-neutral batches. | GPU context, swapchain, command queue, window. |
| `heavy_slug_vulkan` | Vulkan buffers, shader objects, frame binding, draw recording. | Instance, surface, swapchain, queue policy. |
| `heavy_slug_metal` | Metal bridge state, buffers, pipeline state, frame slots. | Cocoa app lifecycle. |
| Demo code | Native Win32, Wayland, Cocoa hosts, and shared scene/input helpers. | Library API policy. |

## Build Dependencies

| Area | Build requirements | Runtime/demo requirements |
| --- | --- | --- |
| Core | Zig `0.16.0`, C/C++ toolchain, pinned package fetch on first build. | None beyond the embedding application. |
| Shaders and backends | `slangc` with Slang 2026 support. | Backend-specific GPU runtime. |
| Vulkan backend | Lazy `vulkan-zig` and Vulkan Headers packages. | Vulkan 1.4, `VK_EXT_mesh_shader`, `VK_EXT_shader_object`, dynamic rendering, push descriptors. |
| Windows Vulkan demo | Native Win32 host; links `user32`; embeds a Per-Monitor-V2/long-path/Segment-Heap manifest; loads the Vulkan loader at runtime. | Vulkan-capable Windows 11 system. |
| Linux Vulkan demo | `wayland-scanner`, `wayland-client`, `xkbcommon`, current Wayland client headers, and pinned `wayland-protocols` 1.48 XML fetched by Zig. | GNOME 50/Mutter 50.x-compatible Wayland session and Vulkan loader/driver. |
| Metal backend/demo | macOS 26.0 or newer deployment target, Apple Swift `6.3` or newer selected by `xcrun --sdk macosx`, Apple SDK with Metal 4 APIs, `Metal`, `QuartzCore`, `Foundation`, `AppKit`, and `SwiftUI` for the demo. | Metal 4 capable device and native SwiftUI/AppKit host. |

Important dependency facts:

- FreeType and HarfBuzz are pinned source dependencies in `build.zig.zon` and
  are built statically by the Zig build. Normal builds do not require system
  FreeType or HarfBuzz packages.
- Core-only `zig build` and `zig build test` do not require `slangc`, Vulkan,
  Metal, Wayland, Cocoa, or a window toolkit.
- Vulkan and Vulkan Headers stay lazy; they are fetched only when the Vulkan
  backend or Vulkan demo is requested.
- `-Ddemo-backend=` is interpreted only when `-Ddemo=true`; backend-only builds
  use `-Dvulkan=true` or `-Dmetal=true`.
- Metal/Cocoa bridge code is Swift. Swift `@c` exports use only pointers,
  integer sizes, scalar values, and explicit out parameters so Zig mirrors the
  ABI directly with `extern` declarations and does not translate bridge headers.
- Fallible Metal/Cocoa bridge creation calls return named status values and
  write owned handles through explicit out parameters. UTF-8 data crosses as
  pointer/length pairs, and diagnostics are written into caller-provided byte
  buffers.
- Cocoa exposes borrowed Metal host objects through explicit out pointers for
  `id<MTLDevice>`, `id<MTL4CommandQueue>`, and `CAMetalLayer *`; the Metal
  bridge retains those objects internally.
- Swift bridge sources compile with the `xcrun --sdk macosx` selected Apple
  Swift `6.3` or newer compiler, `-swift-version 6`, an explicit macOS SDK,
  and an explicit Apple Swift target triple derived from the Zig target. The
  Zig optimize mode maps to `-Onone`, `-O`, or `-Osize`, and Swift module
  caches are emitted under the Zig build cache. Swift sources are linted with
  `zig build swift-format-lint`, which runs `swift format lint --strict`
  through `xcrun --sdk macosx`.
- Internal bridge failures are represented without exceptions and mapped back
  to Zig error sets.
- The demo hosts are deliberately native: Win32 on Windows, Wayland on Linux,
  and a SwiftUI/AppKit host on macOS. GLFW/SDL-style toolkit dependencies are
  not part of the current build model.
- Linux demo builds can override the protocol scanner with
  `-Dwayland-scanner=`. Protocol XML is generated from the lazy
  `wayland_protocols_src` Zig dependency, not from the system
  `wayland-protocols` package.

## Public Modules

| Module | Enabled by | Purpose |
| --- | --- | --- |
| `heavy_slug` | default | Core public types and backend-neutral renderer logic. |
| `heavy_slug_vulkan` | `-Dvulkan=true` or Vulkan demo | Vulkan 1.4 / SPIR-V 1.6 shader-object backend. |
| `heavy_slug_metal` | `-Dmetal=true` or Metal demo | macOS Metal 4 backend. |

Generated shader-blob modules, Slang reflection structs, and third-party
Vulkan generator output are private build-graph imports rather than public
package modules.

Stable top-level core exports include `FontHandle`, `FontSource`,
`FontOptions`, `TextRun`, `FrameToken`, `Color`, `Transform`, `View`,
`PrecisionPolicy`, `FillRule`, and `ShaderStats`.

Backend modules expose `Context`, `Renderer`, `Frame`, `Target`,
`RendererOptions`, `FontHandle`, `FrameToken`, `Stats`, and
`shader_stats_enabled`. The Metal backend also exposes `Host`, the
`id<MTLDevice>` / `id<MTL4CommandQueue>` / `CAMetalLayer *` creation contract
used by the Swift bridge. The bridge retains those objects internally, while
the host keeps the layer attached and configured for presentation. Metal bridge
calls cross Swift `@c` functions as explicit status/out-handle results plus
pointer/length UTF-8 buffers rather than implicit null-pointer failures or
NUL-terminated strings.

<details>
<summary>Typical frame shape</summary>

```zig
const heavy_slug = @import("heavy_slug");

// After the selected backend renderer has been initialized by the host:

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{
    .size_px = 32,
});

const view = heavy_slug.View.identity(width_px, height_px);
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
  -> GlyphMeshlet stream
  -> backend frame submission
  -> mesh/fragment shaders
```

| Stage | Key invariant |
| --- | --- |
| Shaping | Unicode shaping is delegated to HarfBuzz. |
| Outline capture | Glyphs stay as outline data; there is no CPU raster pass. |
| Cubic encoding | Lines, quadratics, and cubics share one tiered fixed-point GPU representation. |
| Cache | Glyph blobs are reused through a backend-owned byte pool. |
| CPU meshlet stream | Visible glyphs are expanded into bounded h-band strips before submission. |
| GPU culling | Mesh shaders still reject clipped or degenerate strips conservatively. |
| Fragment coverage | Coverage is integrated analytically from the encoded curves. |

## Backend Notes

| Backend | Resource model | Host responsibility |
| --- | --- | --- |
| Vulkan | One glyph blob buffer, per-frame glyph and meshlet buffers, shader objects, optional stats buffer. | Provide Vulkan objects, command buffers, render targets, and completed frame tokens. |
| Metal | Bridge-owned glyph and meshlet buffers, Metal 4 mesh pipeline state, argument tables, and per-command resource plus drawable residency. | Provide a Metal 4 device, command queue, configured `CAMetalLayer`, and app lifecycle. |

Frame lifetime is explicit. Backends return `FrameToken` values on submit, and
cached GPU storage is retired only after the host reports completed work.

The Vulkan backend intentionally uses byte-offset `GlyphBlobRef` values rather
than per-glyph descriptor slots and binds mesh and fragment stages as linked
`VK_EXT_shader_object` shader objects. The Metal backend follows the
Metal 4 command and argument-table path exposed through the Swift bridge; it
keeps a mesh `MTLRenderPipelineState` because Metal dynamic
libraries and pipeline dynamic linking do not replace the render pipeline state
model for this renderer.

## Shader Layout

| Path | Role |
| --- | --- |
| `shaders/core/` | Shared ABI, coverage, h-band, chart mapping, and stats logic. |
| `shaders/backend_vulkan/` | Vulkan resource binding shim. |
| `shaders/backend_metal/` | Metal resource binding shim. |
| `shaders/entries/mesh.slang` | Mesh shader entry for CPU-authored glyph meshlets. |
| `shaders/entries/fragment.slang` | Fragment shader entry. |

Shader sources use explicit Slang 2026 modules. `build/shaders.zig` compiles
source-declared entry points to SPIR-V 1.6 for Vulkan and Metal Shading
Language for Metal. GPU ABI structs are generated from Slang reflection by
`tools/layout_gen.zig`.

<details>
<summary>Shader output paths</summary>

```text
zig-out/shaders/spirv/mesh.spv
zig-out/shaders/spirv/fragment.spv
zig-out/shaders/msl/mesh.metal
zig-out/shaders/msl/fragment.metal
```

</details>

## Diagnostics

| Diagnostic source | Signals |
| --- | --- |
| CPU/backend debug stats | Shaping counts, cache hits/misses, precision insufficiency, uploads, retirements, pool state, backend binding work. |
| Shader stats opt-in | Submitted glyph/meshlet counts, draw chunks, emitted meshlets, explicit meshlet-cull reasons, candidate-path usage, fallback scans, fragment pressure. |

Enable shader counters only when investigating GPU behavior:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
```

Backend debug counters are exposed through `Renderer.stats()` in Debug builds.

## Project Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public core module. |
| `src/core/` | Types, fonts, outlines, blob encoding, cache, renderer core. |
| `src/gpu/` | Backend-neutral GPU ABI markers, mesh limits, shader stats. |
| `src/backends/vulkan/` | Vulkan backend. |
| `src/backends/metal/` | Metal backend and Swift bridge. |
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
| Frame math | Draw submission uses a CPU f64 affine `View`; backends no longer accept f32 projection matrices. |
| Glyph resources | Cached glyph blobs live in a backend-owned byte pool; visible strips live in per-frame meshlet buffers. |
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
| Swift toolchain | system macOS Metal backend/demo dependency | No |
| Wayland client libraries | system Linux demo dependency | No |
| Wayland protocol XML | pinned `wayland-protocols` 1.48 source archive | Yes |

Generated local outputs use the usual Zig paths: `zig-out/`, `.zig-cache/`, and
`zig-pkg/`. They are not source artifacts and should not be committed.

## CI

GitHub Actions are verification-only. The public `ci.yml` workflow is a small
orchestrator that calls reusable workflows for quality, core, shader, Vulkan,
and Metal verification. Local composite actions own Zig and Slang resolution,
tool caching, and Zig package cache restore/save behavior, so platform jobs do
not duplicate toolchain setup details. Zig package dependencies are prefetched
with the same bounded exponential-backoff wrapper on Ubuntu, macOS, and
Windows; Windows jobs enable Git long paths before checkout, then enable
system long paths from the repository script before using the shared
cross-platform toolchain path. The quality gate validates workflow/action YAML,
Zig formatting, Zig environment parsing, Bash syntax and ShellCheck
diagnostics, and PowerShell parser errors before backend jobs start. Workflow
dispatch can override Zig and Slang versions; normal CI reads Zig from
`build.zig.zon` and pins Slang to the repository-supported `2026.9` release.

| Job family | Coverage |
| --- | --- |
| Format and Script Syntax | Zig formatting plus POSIX shell syntax checks. |
| Core | Core library and build-tool tests on Ubuntu, macOS, and Windows. |
| Shaders | `zig build spirv` and `zig build msl` in one shader toolchain job. |
| Vulkan | Ubuntu and Windows Vulkan backend, shader-stat, and native demo build tests. |
| Metal | Swift formatting plus Metal backend, shader-stat, and native demo build tests on macOS. |

## Credit

`heavy-slug` would not exist without Slug. Slug established the practical value
of GPU-side analytic glyph coverage and compact outline data. This project
keeps that foundation while exploring native cubic coverage blobs, CPU-authored
meshlets, mesh shader clipping, generated GPU ABI, and explicit Vulkan 1.4 /
Metal 4 backend boundaries.

## License

MIT. See [LICENSE](LICENSE).
