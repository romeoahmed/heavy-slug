# heavy-slug

`heavy-slug` is a Zig 0.16 GPU text rendering library built around the [Slug algorithm](https://jcgt.org/published/0006/02/02/). It shapes Unicode text with HarfBuzz, encodes glyph outlines into cubic-native Coverage V3 blobs, and renders analytic coverage through opt-in mesh-shader backends.

The core library is intentionally small: it owns fonts, shaping, glyph encoding, cache/pool management, and backend-neutral command generation. Applications provide GPU contexts. GLFW is used only by demos.

## Features

- Resolution-independent text rendering without CPU rasterization or texture atlases.
- FreeType 2.14.3 and HarfBuzz 14.2.0 built from pinned source packages.
- Native outline capture through HarfBuzz draw callbacks, regularized into quantized monotone cubic spans for shader coverage.
- Vulkan SPIR-V 1.6 backend for Windows/Linux with `VK_EXT_mesh_shader`.
- macOS Metal 4 backend using Slang-generated MSL and external Metal host objects.
- Shared shader ABI generated from Slang reflection by `tools/layout_gen.zig`.
- Two-tier glyph cache, reusable byte pool, current-frame eviction safety, and multi-buffered submission paths.

## Requirements

- Zig 0.16.0.
- `slangc` on `PATH` for shader build steps and demos.
- Vulkan backend: Vulkan 1.4, `VK_EXT_mesh_shader`, and `VK_EXT_robustness2`.
- Metal backend: macOS with a mesh-shader capable Metal GPU.

## Quick Start

```bash
zig build
zig build test
zig build test -Dvulkan=true
zig build test -Dmetal=true
```

Run a demo:

```bash
zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16
zig build run -Ddemo=true -Ddemo-backend=metal4
```

The Vulkan demo is intended for Windows/Linux. The Metal demo is intended for macOS and creates a GLFW Cocoa window in demo-only code.

## Using The Library

Import the core module plus one backend module:

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

var frame = renderer.beginFrame();
try frame.drawText(.{
    .font = font,
    .text = "Hello, world!",
    .transform = heavy_slug.Transform.translation(100, 200),
    .color = .white,
});
try frame.submit(.{
    .command_buffer = cmd_buf,
    .projection = projection,
    .viewport = .{ viewport_w, viewport_h },
});
```

Metal uses the same renderer shape, but the app provides host-owned Metal objects:

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

## Project Layout

```text
src/
  root.zig              core public module
  core/                 public/private core types, units, font, outline, blob, render contracts
  gpu/                  backend-neutral GPU resource model declarations
  math/                 PGA motor math
  backends/vulkan/      Vulkan backend module
  backends/metal/       Metal backend module and ObjC++ bridge
  demo/common/          shared GLFW scene/input code
  demo/vulkan/          Vulkan demo host and main
  demo/metal/           Metal demo host and main
  c/                    headers translated by build-system addTranslateC()
build/                  build graph modules for deps, C libs, shaders, backends, and demos
shaders/core/           shared Slang ABI, PGA, and coverage modules
shaders/entries/        Slang task/object, mesh, and fragment entry points
tools/layout_gen.zig    Slang reflection to Zig extern structs
assets/                 test/demo assets
docs/                   architecture spec and phase plans
```

## Build Options

```bash
zig build                             # core library
zig build -Dvulkan=true               # enable Vulkan backend
zig build -Dmetal=true                # enable Metal backend
zig build shaders                     # Slang -> SPIR-V
zig build metal-shaders               # Slang -> Metal 4 MSL
zig build -Doptimize=ReleaseFast      # release build
zig build -Dthinlto=on                # require ThinLTO
zig build -Dthinlto=off               # disable ThinLTO
```

`-Dthinlto=auto` is the default. Zig 0.16 requires LLD for LTO, while Mach-O LLD linking is unsupported, so native macOS release builds skip ThinLTO unless `-Dthinlto=on` is used to require a hard failure.

## Dependencies

All third-party source dependencies are pinned in `build.zig.zon`.

| Dependency | Purpose |
| --- | --- |
| FreeType | Font loading |
| HarfBuzz | Unicode shaping and native glyph outline callbacks |
| vulkan-zig | Vulkan binding generation |
| Vulkan-Headers | `vk.xml` registry for generated bindings |
| GLFW | Demo-only window and input |

`vulkan`, `vulkan_headers`, and `glfw_src` are lazy dependencies. Normal core builds do not fetch backend-only or demo-only packages.

## License

MIT. See [LICENSE](LICENSE).
