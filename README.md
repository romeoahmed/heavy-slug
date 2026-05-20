# heavy-slug

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.4-ac162c)](https://www.vulkan.org/)
[![Metal](https://img.shields.io/badge/Metal-4-8f8f8f)](https://developer.apple.com/metal/)
[![Slang](https://img.shields.io/badge/Slang-2026-2d6cdf)](https://shader-slang.org/)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)

`heavy-slug` is a Zig 0.16 text rendering library for analytic,
resolution-independent glyph coverage on modern GPUs. It shapes Unicode with
HarfBuzz, captures native outlines through FreeType, encodes compact cubic
coverage blobs, and renders text through mesh and fragment shaders on
Vulkan 1.4 and Metal 4.

The project follows the core idea of
[Slug](https://jcgt.org/published/0006/02/02/): keep glyph coverage analytic
instead of rasterizing it into an atlas. `heavy-slug` updates that approach for
current graphics APIs with cubic-native blobs, CPU-authored meshlet streams,
reflection-generated GPU layouts, and host-owned backend lifetimes.

```text
UTF-8 -> HarfBuzz shaping -> native outlines -> coverage blobs -> CPU meshlets -> analytic GPU coverage
```

## Why It Exists

Text renderers usually trade between atlas management, signed-distance-field
reconstruction artifacts, and dense outline tessellation. `heavy-slug` takes a
different route:

- Glyphs are cached as outline coverage data, not pixels.
- Visible glyphs become bounded h-band meshlets before submission.
- Mesh shaders reject empty or clipped work early.
- Fragment shaders integrate the encoded curves analytically.
- Applications keep control of windows, devices, queues, swapchains, and frame
  pacing.

This makes the library a rendering component rather than a UI framework or
windowing toolkit.

## Quick Start

```bash
zig build
zig build test
```

Common commands:

| Goal | Command |
| --- | --- |
| Build the backend-neutral core library | `zig build` |
| Run core and build-tool tests | `zig build test` |
| Build and test Vulkan backend | `zig build test -Dvulkan=true` |
| Build and test Metal backend | `zig build test -Dmetal=true` |
| Compile SPIR-V shaders | `zig build spirv` |
| Compile Metal shaders | `zig build msl` |
| Run Vulkan demo on Windows/Linux | `zig build run -Ddemo=true -Ddemo-backend=vulkan` |
| Run Metal demo on macOS | `zig build run -Ddemo=true -Ddemo-backend=metal` |

`-Ddemo-backend=auto` selects Vulkan on Windows/Linux and Metal on macOS.
`-Dshader-stats=true` enables opt-in GPU counter buffers for backend and shader
diagnostics.

## Requirements

| Area | Requirement |
| --- | --- |
| Core | Zig `0.16.0` and a C/C++ toolchain. FreeType `2.14.3` and HarfBuzz `14.2.0` are pinned source dependencies and are built statically by Zig. |
| Shaders | `slangc` with Slang 2026 support, SPIR-V 1.6 output, and Metal `metallib_4_0` output. CI pins Slang `2026.9`. |
| Vulkan backend | Vulkan 1.4, `VK_EXT_mesh_shader`, `VK_EXT_shader_object`, dynamic rendering, core push descriptors, and sufficient mesh shader limits. |
| Windows Vulkan demo | Windows 11, Vulkan loader and driver. The host is native Win32/ntdll with a modern manifest. |
| Linux Vulkan demo | Wayland client libraries, `wayland-scanner`, `xkbcommon`, and the pinned `wayland-protocols` 1.48 XML dependency. |
| Metal backend/demo | macOS 26.0 or newer target, Apple Swift 6.3 or newer through `xcrun --sdk macosx`, an SDK exposing Metal 4, and the Metal/QuartzCore/Foundation/AppKit/SwiftUI frameworks needed by the bridge and demo. |

Core-only builds do not require `slangc`, Vulkan, Metal, Wayland, Cocoa, or any
window toolkit. Vulkan packages and Wayland protocol XML are lazy build
dependencies.

## Architecture

```text
Application
  owns window, graphics device, queues, swapchain/layer, frame completion
      |
      v
Backend module: heavy_slug_vulkan or heavy_slug_metal
  owns GPU buffers, shader state, backend draw recording/submission glue
      |
      v
Core module: heavy_slug
  owns fonts, shaping, outline encoding, glyph cache metadata, draw batches
      |
      v
Slang mesh and fragment shaders
  clip meshlets and integrate analytic coverage
```

| Layer | Owns | Does not own |
| --- | --- | --- |
| `heavy_slug` | Public value types, font loading, shaping, outline regularization, coverage blob encoding, cache metadata, renderer-core batching. | GPU contexts, command buffers, swapchains, layers, surfaces, windows, or toolkits. |
| `heavy_slug_vulkan` | Vulkan buffers, push-descriptor binding, shader objects, dynamic-state draw recording. | Vulkan instance/device creation, WSI policy, command-buffer lifetime, queue submission. |
| `heavy_slug_metal` | Swift-backed Metal 4 context, buffers, frame slots, mesh pipeline submission. | Cocoa application lifecycle and `CAMetalLayer` attachment. |
| `demo/` | Native Win32, Wayland, and SwiftUI/AppKit hosts plus shared scene/input code. | Library API policy. |

The important invariant is ownership: core prepares text and cache data; a
backend turns that data into GPU commands; the application remains the graphics
and window-system owner.

## Technical Highlights

- **Analytic coverage:** glyph edges remain curve data until fragment shading.
- **Cubic-native blob ABI:** lines, quadratics, and cubics share a compact
  32-bit word stream with explicit protocol magic and `major.minor` versioning.
- **Precision tiers:** f64 CPU transforms choose fixed-point blob precision for
  stable high-zoom rendering while rejecting unsupported transforms early.
- **Single glyph pool:** cached glyph blobs are addressed by byte-offset
  `GlyphBlobRef` values rather than per-glyph descriptors.
- **CPU-authored meshlets:** core emits bounded h-band strips so GPU work is
  predictable and mesh shader limits are checked up front.
- **Reflection-owned GPU ABI:** Slang reflection drives generated Zig extern
  structs; generated tests check size and offset contracts.
- **Native demos:** Windows uses native Win32/ntdll, Linux uses Wayland
  xdg-shell/client-side decorations, and macOS uses SwiftUI/AppKit with a
  `CAMetalLayer`.

## Public API

The default package module is `heavy_slug`. Optional backend modules are enabled
by build options:

| Module | Enable with | Purpose |
| --- | --- | --- |
| `heavy_slug` | default | Backend-neutral types, font/text inputs, renderer options, shader stats type. |
| `heavy_slug_vulkan` | `-Dvulkan=true` or Vulkan demo | Vulkan 1.4 backend. |
| `heavy_slug_metal` | `-Dmetal=true` or Metal demo | Metal 4 backend. |

Stable top-level core exports include:

- `FontSource`, `FontOptions`, `FontHandle`
- `TextRun`
- `Color`, `Transform`, `View`
- `PrecisionPolicy`, `FillRule`
- `RendererOptions`, `FrameToken`, `ShaderStats`

Backend modules expose the same high-level rendering flow through `Context`,
`Renderer`, `Frame`, `Target`, `RendererOptions`, `FontHandle`, `FrameToken`,
`Stats`, and `shader_stats_enabled`.

Typical frame shape:

```zig
const heavy_slug = @import("heavy_slug");

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

const token = try frame.submit(target);
```

Vulkan hosts report completed GPU work with `Renderer.markFrameComplete(token)`.
The Metal backend tracks completion through its bridge-managed frame slots and
drains submitted work during teardown.

## Backend Contracts

### Vulkan

Hosts create the Vulkan instance, surface, physical-device selection, logical
device, queues, render targets, command buffers, and submissions. The backend
publishes:

- `required_api_version`
- `required_device_extensions`
- `Context.requiredFeatureChain()`
- `Context.checkDeviceSupport(...)`

The backend validates the enabled device again when wrapping it. Rendering uses
Vulkan 1.4 push descriptors, linked `VK_EXT_shader_object` mesh/fragment shader
objects, dynamic rendering, and CPU-authored meshlet draws. It does not allocate
frame-local descriptor pools or use descriptor indexing as the glyph addressing
model.

### Metal

Hosts provide borrowed `id<MTLDevice>`, `id<MTL4CommandQueue>`, and
`CAMetalLayer *` objects through `heavy_slug_metal.Host`. The Swift bridge
retains the objects internally, validates protocol-versioned request blocks,
owns Metal buffers and frame-slot synchronization, and encodes the Metal 4 mesh
render path.

Zig-facing bridge declarations live in `src/backends/metal/context.zig`; the
renderer layer stays focused on shared `RendererCore` coordination and frame
resources.

## Shader And GPU ABI

Shader sources live under `shaders/`:

| Path | Role |
| --- | --- |
| `shaders/core/` | Shared ABI, chart mapping, h-band candidate traversal, coverage integration, stats, and math helpers. |
| `shaders/backend_vulkan/` | Vulkan binding shim. |
| `shaders/backend_metal/` | Metal binding shim. |
| `shaders/entries/mesh.slang` | Mesh shader entry. |
| `shaders/entries/fragment.slang` | Fragment shader entry. |

`build/shaders.zig` is the target and capability policy. It compiles Slang 2026
sources to SPIR-V 1.6 and Metal Shading Language, treats warnings as errors,
and invokes `tools/layout_gen.zig` to generate Zig GPU structs from reflection.

The resource model is intentionally small:

- one glyph blob storage buffer,
- one glyph instance buffer per frame slot,
- one meshlet buffer per frame slot,
- an optional shader-stats buffer.

## Demos

The demos exercise backend integration without introducing a cross-platform
window toolkit.

| Demo path | Platform host |
| --- | --- |
| `demo/vulkan/` | Shared Vulkan WSI/device/frame loop for Windows and Linux. |
| `demo/platform/windows.zig` | Titled Windows 11 native host with per-monitor DPI, DWM titlebar theming, and selected ntdll/win32u use. |
| `demo/platform/wayland.zig` | Wayland xdg-shell host with client-side decorations, fractional-scale sizing, cursor-shape, viewporter, and linux-dmabuf feedback when available. |
| `demo/metal/` plus `demo/platform/cocoa.swift` | SwiftUI/AppKit host that owns normal Cocoa menus, window chrome, input, and `CAMetalLayer`. |

All demos use `B` to switch between explicit light and dark appearance; they do
not inherit the system appearance as the demo policy.

## Diagnostics

Debug builds expose CPU/backend counters through `Renderer.stats()`. These
cover shaping, cache hits/misses, glyph encoding, uploads, retirements, pool
state, backend binding work, and submitted glyph/meshlet counts.

`-Dshader-stats=true` adds GPU counter buffers for meshlet culling, draw
chunks, emitted meshlets, candidate-index usage, full-scan fallback, fragment
pressure, and coverage integration counts.

## CI

GitHub Actions are verification-only. The public workflow delegates to smaller
reusable workflows for quality, core, shaders, Vulkan, and Metal. Local
composite actions own Zig and Slang setup, Zig package cache policy, and
bounded dependency prefetch retry behavior.

CI runs Zig formatting, script/YAML validation, core tests on Ubuntu/macOS/
Windows, shader compilation, Vulkan backend and demo build tests on Ubuntu and
Windows, Swift format lint, and Metal backend/demo build tests on macOS.

## Project Layout

| Path | Purpose |
| --- | --- |
| `src/root.zig` | Public core module. |
| `src/core/` | Value types, fonts, outlines, blob encoding, cache, renderer core. |
| `src/gpu/` | Backend-neutral GPU resource model, mesh budgets, shader stats. |
| `src/backends/vulkan/` | Vulkan backend. |
| `src/backends/metal/` | Metal backend and Swift bridge. |
| `src/c/` | C headers translated by the build graph. |
| `demo/` | Native demos and shared demo helpers. |
| `shaders/` | Slang modules and shader entries. |
| `tools/layout_gen.zig` | Slang reflection to Zig layout generator. |
| `build/` | Modular Zig build helpers. |
| `assets/` | Repository demo/test assets. |

## Credit

`heavy-slug` would not exist without Slug. Slug demonstrated practical
GPU-side analytic glyph coverage with compact outline data. This project keeps
that foundation while exploring current API boundaries, modern shader stages,
and generated ABI contracts.

## License

MIT. See [LICENSE](LICENSE).
