# heavy-slug

GPU text rendering library for Zig, implementing the [Slug algorithm](https://jcgt.org/published/0006/02/02/) (Eric Lengyel) for exact quadratic Bezier coverage. Renders text entirely on the GPU through opt-in Vulkan SPIR-V 1.6 or macOS Metal 4 mesh-shader backends -- no CPU rasterization, no texture atlases.

## How it works

1. **Shape** -- HarfBuzz performs Unicode text shaping (bidi, ligatures, kerning)
2. **Encode** -- HarfBuzz GPU encodes glyph outlines into Slug-format blobs (quadratic Bezier bands)
3. **Cache** -- Two-tier glyph cache (hot/cold LRU) with promotion queue maps glyphs to backend storage
4. **Dispatch** -- Task/object shader frustum-culls glyphs, mesh shader emits dilated quads from precomputed payload, fragment shader evaluates exact coverage per-pixel

No intermediate bitmaps. Glyphs are resolution-independent and render crisply at any zoom level.

## Requirements

- **Build**: Zig 0.16.0
- **Core module**: FreeType + HarfBuzz are built from source
- **Vulkan backend**: `slangc` on `PATH`, Vulkan 1.4 with `VK_EXT_mesh_shader` and `VK_EXT_robustness2`
- **Metal backend**: macOS with a Metal mesh-shader capable GPU, GLFW Cocoa support, and `slangc` on `PATH`

## Quick start

```bash
# Build library only (default)
zig build

# Run tests
zig build test

# Build and test the Vulkan SPIR-V 1.6 backend
zig build test -Dvulkan=true

# Windows/Linux Vulkan demo
zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16

# macOS Metal 4 demo
zig build run -Ddemo=true -Ddemo-backend=metal4
```

The Windows/Linux demo renders lorem ipsum text with pan (left-drag), zoom (scroll), rotation (right-drag with momentum), dark mode (**B**), reset (**R**), and an FPS counter. The macOS demo creates a GLFW Cocoa window, compiles Slang-generated Metal 4 MSL at runtime, and drives a Metal mesh pipeline through a small ObjC++ bridge. Press **ESC** to exit.

## Usage

`heavy_slug` is the core module. It provides font shaping, glyph encoding, cache/pool utilities, and PGA math without importing a graphics API. Renderers are backend modules: `heavy_slug_vulkan` for Vulkan SPIR-V 1.6 and `heavy_slug_metal` for macOS Metal 4.

```zig
const heavy_slug = @import("heavy_slug");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const pga = heavy_slug.pga;
const vk_text = heavy_slug_vulkan;

// 1. Validate device support
try vk_text.Context.checkDeviceSupport(physical_device, instance_dispatch, allocator);

// 2. Create your VkDevice with vk_text.required_device_extensions enabled
// ...

// 3. Wrap the device
const ctx = vk_text.Context.init(physical_device, device, instance_dispatch, get_device_proc_addr);

// 4. Create a text renderer
var text_renderer = try vk_text.TextRenderer.init(ctx, color_format, allocator, .{});
defer text_renderer.deinit();

// 5. Load fonts
const font = try text_renderer.loadFont("path/to/font.otf", 24);

// 6. Render loop
text_renderer.begin();
try text_renderer.drawText(font, "Hello, world!", pga.Motor.fromTranslation(100, 200), .{ 1, 1, 1, 1 });
text_renderer.flush(cmd_buf, projection_matrix, .{ viewport_w, viewport_h });
```

The Metal API follows the same ownership pattern. Create a context from a native `NSWindow` with `initForCocoaWindow`, or use `initForGlfwWindow` in the demo:

```zig
const heavy_slug_metal = @import("heavy_slug_metal");

var ctx = try heavy_slug_metal.Context.initForGlfwWindow(@ptrCast(window));
defer ctx.deinit();

var text_renderer = try heavy_slug_metal.TextRenderer.init(ctx, allocator, .{});
defer text_renderer.deinit();
```

Glyph positioning uses 2D PGA motors (`Motor`) -- compose translations, rotations, and transforms with a single type that maps directly to GPU memory.

## Architecture

```
src/
  root.zig            -- core API (font, pga, cache, pool)
  font/
    ft.zig            -- FreeType 2.14.3 wrapper
    hb.zig            -- HarfBuzz 14.2.0 wrapper
    glyph.zig         -- FontContext: shape + encode pipeline
  cache/
    glyph.zig         -- two-tier glyph cache
    pool.zig          -- byte pool allocator
  vulkan/
    root.zig          -- Vulkan backend API
    context.zig       -- VulkanContext, device dispatch, feature validation
    descriptors.zig   -- Bindless descriptor table with batched writes, auto-generated GPU structs
    pipeline.zig      -- Mesh shader pipeline, embedded SPIR-V
    renderer.zig      -- TextRenderer: the public rendering API
  metal/
    root.zig          -- Metal backend API
    renderer.zig      -- TextRenderer backed by a Metal glyph-pool buffer
    bridge.h          -- C ABI for Zig -> Metal host bridge
    bridge.mm         -- ObjC++ Cocoa + CAMetalLayer + Metal mesh pipeline
  math/
    pga.zig           -- 2D PGA motors, SIMD via @Vector(4,f32)
  demo/
    glfw.zig          -- GLFW wrapper
    metal4_main.zig   -- macOS Metal 4 demo entry point
shaders/
    slug_task.slang   -- Task/object shader: frustum cull + compaction
    slug_mesh.slang   -- Mesh shader: dilated quad from precomputed payload
    slug_fragment.slang -- Fragment shader: Slug band coverage
    slug_common.slang -- Shared types, constants, BlobReader
    pga.slang         -- Motor math (mirrors pga.zig)
tools/
    layout_gen.zig    -- Generates Zig structs from Slang shader reflection
```

GPU struct types (`GlyphCommand`, `PushConstants`) are auto-generated at build time from shader reflection JSON -- the shader is the single source of truth.

## Dependencies

All compiled from source by `zig build` -- no system packages required.

| Library | Version | Purpose |
|---------|---------|---------|
| [FreeType](https://freetype.org/) | 2.14.3 | Font loading |
| [HarfBuzz](https://harfbuzz.github.io/) | 14.2.0 | Unicode shaping + GPU encoding |
| [vulkan-zig](https://github.com/Snektron/vulkan-zig) | pinned upstream | Vulkan binding generation |
| [GLFW](https://www.glfw.org/) | 3.4 | Window + input (demo only) |

`vulkan`, `vulkan_headers`, and `glfw_src` are lazy dependencies. Vulkan packages are fetched only for `-Dvulkan=true` or Windows/Linux demo builds; GLFW is fetched only for demo builds. Metal uses system frameworks through the ObjC++ bridge. Shader build steps require `slangc`.

## Building

```bash
zig build                             # library (debug)
zig build -Doptimize=ReleaseFast      # library (release, ThinLTO on C deps)
zig build -Dvulkan=true               # configure the Vulkan backend module
zig build -Dmetal=true                # configure the Metal backend module
zig build test                        # library + build tool tests
zig build test -Dvulkan=true          # core + Vulkan backend tests
zig build test -Dmetal=true           # core + Metal backend tests
zig build shaders                     # compile Slang -> SPIR-V
zig build metal-shaders               # compile Slang -> Metal 4 MSL
zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16  # Windows/Linux Vulkan demo
zig build run -Ddemo=true -Ddemo-backend=metal4          # macOS Metal 4 demo
```

## License

[MIT](LICENSE)
