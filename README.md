# heavy-slug

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.4-ac162c)](https://www.vulkan.org/)
[![Metal](https://img.shields.io/badge/Metal-4-8f8f8f)](https://developer.apple.com/metal/)
[![Slang](https://img.shields.io/badge/Slang-2026-2d6cdf)](https://shader-slang.org/)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines, encodes cubic coverage blobs, and renders those blobs with task,
mesh, and fragment shaders on Vulkan 1.4 and Metal 4.

It starts from the [Slug algorithm](https://jcgt.org/published/0006/02/02/),
then takes a modern path: cubic-native analytics, mesh/task shader culling, one
glyph-pool buffer, generated GPU ABI, and shared Slang sources for Vulkan and
Metal.

```text
HarfBuzz shaping -> native outlines -> cubic blobs -> mesh/task culling -> analytic coverage
```

| Design promise | What it means |
| --- | --- |
| Analytic until the fragment shader | No CPU glyph raster atlas or SDF reconstruction step. |
| Backend opt-in | Core builds do not fetch Vulkan, Metal, window-system code, or `slangc`. |
| Host-owned graphics lifecycle | Applications keep control of devices, queues, swapchains, and frame completion. |
| Reflection-owned ABI | Slang reflection generates the Zig GPU structs consumed by backends. |

## Quick Start

| Goal | Command | Notes |
| --- | --- | --- |
| Core build | `zig build` | No GPU backend, no `slangc` needed. |
| Core tests | `zig build test` | Builds pinned FreeType/HarfBuzz source deps. |
| Vulkan tests | `zig build test -Dvulkan=true` | Needs `slangc`; supported on Windows/Linux targets. |
| Metal tests | `zig build test -Dmetal=true` | Needs macOS + Metal 4 SDK + `slangc`. |
| SPIR-V shaders | `zig build spirv` | Emits SPIR-V 1.6 shader outputs. |
| Metal shaders | `zig build msl` | Emits Metal Shading Language outputs. |

<details>
<summary>Demo commands</summary>

```bash
zig build run -Ddemo=true -Ddemo-backend=vulkan
zig build run -Ddemo=true -Ddemo-backend=metal
```

`-Ddemo-backend=auto` resolves to Vulkan on Windows/Linux and Metal on macOS.

</details>

<details>
<summary>Useful verification commands</summary>

```bash
zig fmt --check build.zig src/ tools/
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
zig build -Doptimize=ReleaseFast
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

Text rendering usually asks you to choose between a fast cached approximation
and a precise but geometry-heavy path. `heavy-slug` is built around a different
tradeoff: keep compact outline data on the GPU, cull aggressively, and compute
coverage analytically where pixels are finally known.

| Common text path | Typical tradeoff | `heavy-slug` path |
| --- | --- | --- |
| CPU raster atlas | Atlas invalidation, scale artifacts | Analytic coverage from outline blobs. |
| Signed-distance field | Reconstruction artifacts | Direct cubic crossing and integration. |
| Outline tessellation | Geometry cost, MSAA dependence | Mesh/task culling plus analytic fragment coverage. |

Core highlights:

| Highlight | Meaning |
| --- | --- |
| Cubic-native coverage | TrueType quadratics are raised to cubics; CFF/CFF2 cubics stay cubic. |
| Conservative h-band culling | Task/mesh stages reduce work only after proving regions are empty. |
| Single glyph-pool buffer | `GlyphBlobRef` is a byte offset; there are no per-glyph descriptors. |
| Host-owned GPU state | Applications own devices, queues, swapchains, windows, and frame completion. |
| Shared Slang source | Vulkan SPIR-V and Metal MSL come from the same shader modules. |
| Reflection ABI | GPU structs are generated from Slang reflection by `tools/layout_gen.zig`. |

## Architecture At A Glance

```text
Application
  owns window / device / queue / swapchain / frame completion
      |
      v
Backend module: heavy_slug_vulkan or heavy_slug_metal
  owns GPU buffers, pipeline objects, frame submission glue
      |
      v
Core module: heavy_slug
  shapes text, captures outlines, encodes blobs, manages cache, emits instances
      |
      v
Task -> Mesh -> Fragment shaders
  cull glyph bands, tighten strips, integrate analytic coverage
```

| Layer | Owns | Does not own |
| --- | --- | --- |
| `heavy_slug` | Shaping, outline encoding, cache metadata, backend-neutral batches. | GPU context, window, swapchain. |
| `heavy_slug_vulkan` | Vulkan glyph pool, push frame bindings, pipeline, draw recording. | Instance, surface, swapchain, queue submission policy. |
| `heavy_slug_metal` | Metal 4 bridge objects, argument tables, pipeline, buffers. | Cocoa app lifecycle. |
| Demo code | Native Win32, Wayland, and Cocoa hosts plus shared scene input. | Core library behavior. |

The important boundary is ownership: `heavy_slug` prepares text work, while the
application remains the graphics host.

## Build Dependencies

The table below reflects `build.zig`, `build/`, `build.zig.zon`, and the CI
workflow.

| Target | Required to build | Extra for demo/runtime |
| --- | --- | --- |
| Core, all platforms | Zig `0.16.0`; C/C++ toolchain; first-build network access for pinned Zig packages. | No `slangc`, Vulkan, Metal, or window-system dependencies required. |
| Vulkan backend, Linux | Zig; `slangc` with Slang 2026 and SPIR-V 1.6 support; lazy `vulkan_headers`; lazy `vulkan-zig`. | Vulkan loader/driver; Vulkan 1.4; core `pushDescriptor`; `VK_EXT_mesh_shader`; task/mesh features; sufficient mesh limits. |
| Vulkan demo, Linux | Vulkan backend deps; `wayland-scanner`; `wayland-client` and `xkbcommon` headers/libraries; `wayland-protocols` xdg-shell, viewporter, and fractional-scale XML. | Wayland-capable desktop/session; Vulkan loader/runtime loaded at startup; client-side decorations are drawn with `wl_subsurface`/`wl_shm`. |
| Vulkan backend/demo, Windows | Zig; `slangc` with Slang 2026 and SPIR-V 1.6 support; lazy `vulkan_headers`; lazy `vulkan-zig`; Win32 `user32`. | Vulkan loader/runtime loaded at startup; DWM dark-titlebar support loaded from `dwmapi.dll`; Vulkan 1.4 driver; core `pushDescriptor`; `VK_EXT_mesh_shader`. |
| Metal backend, macOS | Zig; `slangc` with Slang 2026 and `metallib_4_0` support; Apple SDK with Metal 4 APIs; Objective-C++ support; `Metal`, `QuartzCore`, `Foundation`. | GPU supporting `MTLGPUFamilyMetal4`; host supplies `id<MTLDevice>`, `id<MTL4CommandQueue>`, `CAMetalLayer *`. |
| Metal demo, macOS | Metal backend deps; native Cocoa `NSWindow` host. | `Cocoa`, `QuartzCore`, `Metal`, `Foundation`. |

Important dependency facts:

- FreeType and HarfBuzz are pinned source packages in `build.zig.zon` and are
  built statically; system FreeType/HarfBuzz installs are not required.
- The bundled FreeType build is intentionally outline-focused: it compiles the
  scalable TrueType/OpenType, CFF/CID, Type 1, and Type42 loaders used through
  HarfBuzz `hb-ft`, and disables bitmap/compression/SVG helper dependencies
  such as zlib, bzip2, libpng, Brotli, and FreeType's own HarfBuzz auto-hint
  integration.
- `slangc` is needed for shader generation, backend builds/tests, demos, and
  reflected GPU ABI generation. The shader build uses explicit Slang 2026
  modules, warning-as-error diagnostics, restrictive capability checks, and
  source-declared `[shader(...)]` entry points.
- `vulkan` and `vulkan_headers` are lazy dependencies; core-only builds do not
  fetch them.
- The Vulkan demo does not link a Vulkan import library. Its platform layer
  loads the system Vulkan loader at startup and then uses `vkGetInstanceProcAddr`.
- The Windows demo intentionally stays on direct Win32 rather than WinRT or
  Windows App SDK UI layers because Vulkan WSI needs an `HWND` and the demo's
  job is window/surface/input hosting, not application UI composition. It still
  follows the scene's light/dark toggle for the non-client title bar through
  `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` and handles per-monitor
  DPI changes through the normal `WM_DPICHANGED` resize path. Initial demo
  dimensions are treated as logical pixels and converted with the window's
  `GetDpiForWindow()` value after Windows has assigned the hidden window to a
  monitor.
- Linux demo builds use xdg-shell, viewporter, and fractional-scale protocol
  sources generated by `wayland-scanner`. Override
  `-Dwayland-scanner=` or `-Dwayland-protocols-dir=` when those tools live
  outside the default Linux paths. Keyboard events use `xkbcommon` keymaps from
  `wl_keyboard.keymap`, with raw evdev keycodes only as a fallback.
- The Wayland demo requires `fractional-scale-v1` and `wp_viewporter`. It keeps
  xdg-shell window sizes in surface-local logical coordinates, renders the
  Vulkan swapchain and client-side decoration shm buffers at the
  compositor-preferred fractional scale, then maps those buffers back to the
  logical surface size with `wp_viewport`.
- The Wayland demo always draws a small client-side frame using Wayland core
  `wl_subsurface` and `wl_shm`, then delegates drag/resize to xdg-shell
  `move`/`resize` requests. Decoration buffers are bounded per decoration part
  and wait for `wl_buffer.release` before reuse or teardown.
- The macOS demo installs a minimal Cocoa app menu with About, Close Window,
  and Quit actions while keeping the window chrome native and leaving Metal
  device, command queue, and `CAMetalLayer` ownership inside the demo host.

## Public Modules

| Module | Enabled by | Purpose |
| --- | --- | --- |
| `heavy_slug` | default | Core public types and backend-neutral renderer logic. |
| `heavy_slug_vulkan` | `-Dvulkan=true` or Vulkan demo | Vulkan 1.4 / SPIR-V 1.6 mesh-shader backend. |
| `heavy_slug_metal` | `-Dmetal=true` or Metal demo | macOS Metal 4 backend. |

Stable top-level core exports include `FontHandle`, `FontSource`,
`FontOptions`, `TextRun`, `FrameToken`, `Color`, `Transform`, `Viewport`,
`Projection`, `FillRule`, and `ShaderStats`.

Backend modules expose `Context`, `Renderer`, `Frame`, `Target`,
`RendererOptions`, `FontHandle`, `FrameToken`, `Stats`, and
`shader_stats_enabled`. The Metal module also exposes `Host`, the borrowed
`id<MTLDevice>` / `id<MTL4CommandQueue>` / `CAMetalLayer *` contract used to
create a backend context.

<details>
<summary>Basic Vulkan usage shape</summary>

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

</details>

<details>
<summary>Basic Metal usage shape</summary>

```zig
const heavy_slug_metal = @import("heavy_slug_metal");

const host = heavy_slug_metal.Host{
    .device = mtl_device,
    .command_queue = mtl4_queue,
    .layer = metal_layer,
};

var ctx = try heavy_slug_metal.Context.init(host);
defer ctx.deinit();

var renderer = try heavy_slug_metal.Renderer.init(ctx, allocator, .{});
defer renderer.deinit();
```

</details>

## Pipeline

```text
UTF-8 text
  -> HarfBuzz shaping
  -> HarfBuzz outline draw callbacks
  -> cubic normalization and regularization
  -> CoverageBlob with h-band candidates
  -> GlyphStore cache + byte pool
  -> GlyphBatch of GlyphInstance records
  -> backend frame submission
  -> task/mesh/fragment shaders
```

| Stage | Key invariant |
| --- | --- |
| Outline capture | No CPU rasterization. |
| Cubic normalization | Lines, quadratics, and native cubics share one GPU representation. |
| Regularization | Quantized cubic spans remain stable for shader evaluation. |
| H-band index | Accelerates common fragments while preserving full-scan fallback. |
| Task/mesh culling | Discards only regions proven unable to affect coverage. |
| Fragment coverage | Solves cubic crossings and integrates clipped `x dy` area. |

## Backend Notes

| Backend | Resource model | Required API path |
| --- | --- | --- |
| Vulkan | One glyph blob storage buffer; one frame-local `GlyphInstance[]`; optional shader stats buffer; `FrameBindings` pushes per-frame buffer views. | Vulkan 1.4, SPIR-V 1.6, core `pushDescriptor`, `VK_EXT_mesh_shader`, dynamic rendering. |
| Metal | Bridge-owned buffers; per-frame `MTL4ArgumentTable`; Metal residency set. | Metal 4, `MTL4CommandQueue`, `MTL4CommandAllocator`, `MTL4Compiler`, `MTL4MeshRenderPipelineDescriptor`. |

The current Vulkan hot path is the single glyph-pool buffer plus `GlyphBlobRef`
byte offsets. Vulkan frame bindings use core 1.4 push descriptors, so there is
no per-frame descriptor pool or descriptor set allocation. The Metal backend
follows the Metal 4 command and argument-table model rather than the older
command-buffer and stage-specific setter model.

Frame lifetime is explicit. Backends return `FrameToken` values on submit, and
cached glyph storage is retired only after the backend reports completed work.

## Shader Layout

| Path | Role |
| --- | --- |
| `shaders/core/` | Shared ABI, PGA, coverage, h-band logic. |
| `shaders/backend_vulkan/` | Vulkan resource binding shim. |
| `shaders/backend_metal/` | Metal resource binding shim. |
| `shaders/entries/task.slang` | Task shader entry. |
| `shaders/entries/mesh.slang` | Mesh shader entry. |
| `shaders/entries/fragment.slang` | Fragment shader entry. |

Shader sources are explicit Slang 2026 modules. `build/shaders.zig` compiles
the source-declared entry points with `spirv_1_6` for Vulkan and
`metallib_4_0` for Metal. SPIR-V specification revisions are Khronos document
revisions rather than selectable module versions; generated SPIR-V declares
version 1.6 in the module header.

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
| CPU/backend debug stats | Shaping counts, cache hits/misses, encoded spans, uploaded bytes, pool fragmentation, deferred retirements, Vulkan binding writes/pushes, Metal frame-slot waits. |
| Shader stats opt-in | Visible glyphs, emitted mesh tiles, mesh culls, fragment counts, candidate-path usage, full-scan fallback, curve tests, zero-coverage fragments. |

Enable shader counters only when investigating performance:

```bash
zig build test -Dvulkan=true -Dshader-stats=true
zig build test -Dmetal=true -Dshader-stats=true
```

The shader counters are meant to explain where work went: task visibility,
meshlet emission, h-band candidate efficiency, full-scan fallback rate, and
fragment-side curve integration pressure.

## Project Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public core module. |
| `src/core/` | Types, font, outline, blob, cache, renderer core. |
| `src/gpu/` | GPU ABI marker, mesh limits, shader stats, resource model notes. |
| `src/backends/vulkan/` | Vulkan backend, including `bindings.zig` push-frame binding helpers. |
| `src/backends/metal/` | Metal backend, Zig bridge context, and Objective-C++ bridge. |
| `src/demo/` | Demo-only Vulkan/Metal entry points, native platform hosts, and shared scene/input code. |
| `src/c/` | Headers translated by build-system `addTranslateC()`. |
| `build/` | Modular Zig build graph. |
| `shaders/` | Slang shader modules and entries. |
| `tools/layout_gen.zig` | Slang reflection to Zig extern structs. |
| `assets/` | Repository test/demo assets. |

## Implementation Notes

| Area | Current design |
| --- | --- |
| Coverage | Analytic outline coverage is preserved until the fragment shader. |
| Culling | Task/mesh stages perform conservative work reduction. |
| Core scope | The core is backend-neutral and window-system-free. |
| Host scope | Applications provide GPU contexts, queues, swapchains, and frame completion. |
| Glyph resources | Cached glyph blobs live in one backend-owned glyph-pool buffer. |
| Blob references | `GlyphBlobRef` values are byte offsets instead of descriptor slots. |
| GPU ABI | GPU structs are generated from Slang reflection. |
| Reflection guardrails | `tools/layout_gen.zig` rejects conflicting reflected layouts and emits generated layout tests. |
| C headers | C declarations are translated through build-system `addTranslateC()` modules. |

`RendererCore` is the shared spine: it loads fonts, shapes runs, encodes missing
glyphs, maintains cache metadata, writes backend-specific `GlyphInstance`
records, and defers resource retirement through frame tokens. Backend renderers
provide only the upload/retire behavior and the GPU submission path.

## Dependency Summary

| Dependency | Source | Lazy |
| --- | --- | --- |
| FreeType | `build.zig.zon` source archive | No |
| HarfBuzz | `build.zig.zon` source archive | No |
| `vulkan-zig` | pinned Git dependency | Yes |
| Vulkan Headers | pinned Git dependency | Yes |
| Wayland client/protocols | system Linux demo dependency | No |

Generated local build outputs use the usual Zig paths: `zig-out/`,
`.zig-cache/`, and `zig-pkg/`. They are not source artifacts and should not be
committed.

## CI

GitHub Actions run formatting, core tests, Vulkan tests on Ubuntu, Metal tests
on macOS, shader-stat variants, and ReleaseFast builds. Workflow dispatch can
override Zig and Slang versions; the default Zig version is read from
`build.zig.zon`.

| Job family | Coverage |
| --- | --- |
| Lint | `zig fmt --check build.zig src/ tools/` |
| Test | Core, Vulkan, Metal, and shader-stat variants across supported runners. |
| ReleaseFast | Core plus backend release builds on Ubuntu and macOS. |

## Credit

`heavy-slug` would not exist without Slug. Slug established the practical value
of GPU-side analytic glyph coverage and compact outline data. This project
keeps that foundation while exploring native cubic coverage blobs, mesh/task
shader culling, generated GPU ABI, and explicit Vulkan 1.4 / Metal 4 backend
boundaries.

## License

MIT. See [LICENSE](LICENSE).
