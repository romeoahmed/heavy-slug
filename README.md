# heavy-slug

GPU text rendering library for Zig, implementing the [Slug algorithm](https://jcgt.org/published/0006/02/02/) (Eric Lengyel) for exact quadratic Bezier coverage. Renders text entirely on the GPU using Vulkan 1.4 mesh shaders -- no CPU rasterization, no texture atlases.

## How it works

1. **Shape** -- HarfBuzz performs Unicode text shaping (bidi, ligatures, kerning)
2. **Encode** -- HarfBuzz GPU encodes glyph outlines into Slug-format blobs (quadratic Bezier bands)
3. **Cache** -- Two-tier glyph cache (hot/cold LRU) maps glyphs to bindless storage buffer descriptors
4. **Dispatch** -- Task shader frustum-culls, mesh shader emits dilated quads, fragment shader evaluates exact coverage per-pixel

No intermediate bitmaps. Glyphs are resolution-independent and render crisply at any zoom level.

## Requirements

- **GPU**: Vulkan 1.4 with `VK_EXT_mesh_shader` and `VK_EXT_robustness2`
- **Build**: Zig 0.16.0-dev (minimum `0.16.0-dev.3133+5ec8e45f3`)
- **Shader compiler**: [slangc](https://shader-slang.com/) on PATH

## Quick start

```bash
# Build library only (default)
zig build

# Run tests
zig build test

# Build and run the interactive demo
zig build run -Ddemo=true
```

The demo renders lorem ipsum text with pan (left-drag), zoom (scroll), rotation (right-drag with momentum), dark mode (**B**), reset (**R**), and an FPS counter. Press **ESC** to exit.

## Usage

heavy-slug is a Zig library. You provide the Vulkan device; it provides the text renderer.

```zig
const heavy_slug = @import("heavy_slug");
const pga = heavy_slug.pga;
const gpu_context = heavy_slug.gpu_context;
const renderer = heavy_slug.renderer;

// 1. Validate device support
try gpu_context.VulkanContext.checkDeviceSupport(physical_device, instance_dispatch, allocator);

// 2. Create your VkDevice with VulkanContext.required_device_extensions enabled
// ...

// 3. Wrap the device
const ctx = gpu_context.VulkanContext.init(physical_device, device, instance_dispatch, get_device_proc_addr);

// 4. Create a text renderer
var text_renderer = try renderer.TextRenderer.init(ctx, color_format, allocator, .{});
defer text_renderer.deinit();

// 5. Load fonts
const font = try text_renderer.loadFont("path/to/font.otf", 24);

// 6. Render loop
text_renderer.begin();
try text_renderer.drawText(font, "Hello, world!", pga.Motor.fromTranslation(100, 200), .{ 1, 1, 1, 1 });
text_renderer.flush(cmd_buf, projection_matrix, .{ viewport_w, viewport_h });
```

Glyph positioning uses 2D PGA motors (`Motor`) -- compose translations, rotations, and transforms with a single type that maps directly to GPU memory.

## Architecture

```
src/
  root.zig            -- public API (pga, gpu_context, renderer)
  font/
    ft.zig            -- FreeType 2.14.3 wrapper
    hb.zig            -- HarfBuzz 14.1.0 wrapper
    glyph.zig         -- FontContext: shape + encode pipeline
  gpu/
    context.zig       -- VulkanContext, device dispatch, feature validation
    descriptors.zig   -- Bindless descriptor table, auto-generated GPU structs
    pool.zig          -- Bump + free-list sub-allocator for glyph blobs
    cache.zig         -- Two-tier hot/cold LRU glyph cache (O(1) ops)
    pipeline.zig      -- Mesh shader pipeline, embedded SPIR-V
    renderer.zig      -- TextRenderer: the public rendering API
  math/
    pga.zig           -- 2D PGA motors, SIMD via @Vector(4,f32)
shaders/
    slug_task.slang   -- Task shader: frustum cull + workgroup dispatch
    slug_mesh.slang   -- Mesh shader: dilated quad per glyph
    slug_fragment.slang -- Fragment shader: Slug band coverage
    slug_common.slang -- Shared types (GlyphCommand, PushConstants)
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
| [HarfBuzz](https://harfbuzz.github.io/) | 14.1.0 | Unicode shaping + GPU encoding |
| [vulkan-zig](https://github.com/Snektron/vulkan-zig) | latest | Vulkan binding generation |
| [GLFW](https://www.glfw.org/) | 3.4 | Window + input (demo only) |

GLFW is only fetched when building with `-Ddemo=true`.

## Building

```bash
zig build                             # library (debug)
zig build -Doptimize=ReleaseFast      # library (release, ThinLTO on C deps)
zig build -Ddemo=true                 # library + demo executable
zig build run -Ddemo=true             # run demo
zig build test                        # library + build tool tests
zig build test -Ddemo=true            # all tests (library + demo)
zig build shaders                     # compile Slang -> SPIR-V only
```

## License

[MIT](LICENSE)
