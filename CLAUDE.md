# CLAUDE.md

**heavy-slug** -- Zig 0.16.0-dev GPU text renderer using the Slug algorithm (Eric Lengyel) for exact quadratic Bezier coverage via Vulkan 1.4 `VK_EXT_mesh_shader`. Shaders compiled from Slang to SPIR-V 1.6. Library: `src/root.zig`. Demo: `src/main.zig`.

## Commands

```bash
zig fmt src/                          # format
zig build                             # build lib + exe (also compiles shaders)
zig build run [-- args]               # run demo
zig build test                        # run tests (silent on success)
zig build shaders                     # compile Slang -> SPIR-V only
zig build -Doptimize=ReleaseFast      # ReleaseSafe | ReleaseSmall | ReleaseFast
```

## Commits

`git commit -s -S` -- Signed-off-by + GPG signature required. Always include:
```
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

## Architecture

```
src/
  root.zig            -- public API re-exports (pga, gpu_context, renderer)
  main.zig            -- demo executable
  font/
    ft.zig            -- FreeType wrapper: Library, Face, rawHandle
    hb.zig            -- HarfBuzz wrapper: Buffer, Font, GpuDraw, Blob
    glyph.zig         -- FontContext (ft+hb+gpu_draw), EncodedGlyph
  gpu/
    context.zig       -- VulkanContext, DeviceDispatch, InstanceDispatch, feature validation
    descriptors.zig   -- DescriptorTable, auto-generated GlyphCommand/PushConstants
    pool.zig          -- PoolAllocator: bump+freelist sub-allocator for blob VkBuffer
    cache.zig         -- GlyphCache: hot/cold two-tier LRU over descriptor slots
    pipeline.zig      -- Mesh+fragment pipeline, embedded SPIR-V, dynamic rendering
    renderer.zig      -- TextRenderer: init/deinit, loadFont, begin/drawText/flush
  math/
    pga.zig           -- Cl(2,0,1) Motor/Point, @Vector(4,f32) SIMD internals
  demo/
    glfw.zig          -- GLFW 3.4 wrapper with manual Vulkan externs
    vulkan.zig        -- Demo Vulkan bootstrap: instance, device, swapchain, frame sync
shaders/
  pga.slang           -- Motor struct (mirrors pga.zig)
  slug_common.slang   -- GlyphCommand, PushConstants, BlobReader
  slug_task.slang     -- Task shader: frustum cull + mesh dispatch
  slug_mesh.slang     -- Mesh shader: dilated quad per glyph
  slug_fragment.slang -- Fragment shader: Slug band lookup + coverage
tools/
  layout_gen.zig      -- build tool: slangc reflection JSON -> extern struct definitions
```

**Demo** -- `src/main.zig` is an interactive text viewer (hb-gpu-demo style): pan, zoom, right-drag rotation with momentum, dark mode (B), reset (R), FPS counter. Requires GPU with `VK_EXT_mesh_shader`. ESC to exit.

## Dependencies

| Key | Package | Purpose |
|-----|---------|---------|
| `vulkan` | Snektron/vulkan-zig | Vulkan bindings generator |
| `vulkan_headers` | KhronosGroup/Vulkan-Headers | `registry/vk.xml` |
| `freetype_src` | FreeType 2.14.3 | Font rasterization |
| `harfbuzz_src` | HarfBuzz 14.1.0 | Unicode shaping + HarfBuzz GPU |
| `glfw_src` | GLFW 3.4 | Window + Vulkan surface (demo only) |

Add/update: `zig fetch --save <url>` -- hashes are pinned automatically.

## Vulkan Patterns

**Bindings** -- generated at build time from `vk.xml`:
```zig
const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
const vk_gen   = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
const vk_cmd   = b.addRunArtifact(vk_gen);
vk_cmd.addFileArg(registry);
const vulkan_zig = b.addModule("vulkan-zig", .{
    .root_source_file = vk_cmd.addOutputFileArg("vk.zig"),
});
```

**Filtered dispatch** -- `vk.DeviceWrapper` does NOT exist. Use:
```zig
// Define struct with ?vk.PfnXxx = null fields, then:
vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch)
```
Dispatch struct fields use **C names** (`vkCreateInstance`). Wrapper methods use **camelCase** (`createInstance`). See `src/gpu/context.zig`.

**Bool32** -- vulkan-zig `Bool32` is an enum. Use `.true`/`.false` for struct fields (not `vk.TRUE`/`vk.FALSE`). Use `vk.TRUE` only for comparison contexts like `waitForFences`.

**VulkanContext** -- wraps a caller-provided `VkDevice`. Call `VulkanContext.checkDeviceSupport(physical_device, instance_dispatch, allocator)` before device creation to validate mesh shader + robustness2. Then `VulkanContext.init(physical_device, device, instance_dispatch, get_device_proc_addr)` loads the dispatch table and queries memory properties. Internal init functions (`DescriptorTable.init`, `Pipeline.init`, `createMappedBuffer`) accept `VulkanContext` to avoid repeating `device, dispatch` pairs. Required extensions: `VulkanContext.required_device_extensions`.

**Feature chain** -- Vulkan 1.4 instance, SPIR-V 1.6 shaders. Device features use `PhysicalDeviceVulkan12Features` / `PhysicalDeviceVulkan13Features` pNext chain plus `PhysicalDeviceMeshShaderFeaturesEXT` and `PhysicalDeviceRobustness2FeaturesEXT`.

**Wrapper slices** -- Vulkan wrapper functions take slices, not count+pointer pairs (e.g. `waitForFences` takes `[]const Fence`).

## Font Pipeline

**C library builds** -- `buildFreetype()` / `buildHarfbuzz()` / `buildGlfw()` in `build.zig` return `*std.Build.Step.Compile`. `@cImport` needs explicit `mod.addIncludePath()` -- `linkLibrary` alone does not propagate headers.

**Cross-module cImport** -- `ft.zig` and `hb.zig` each have independent `@cImport` blocks; Zig treats them as distinct type namespaces. Bridge `FT_Face` across modules via `*anyopaque`: `ft.Face.rawHandle()` returns `@ptrCast(self.handle.?)`, `hb.Font.createFromFtFace` reconstructs with `@ptrCast(@alignCast(ptr))`.

**FontContext** -- `glyph.FontContext` owns FT_Face + hb_font + reusable hb_gpu_draw.
- `shapeText(text, null, null)` -- auto-detect direction/script via `hb_buffer_guess_segment_properties`
- `encodeGlyph(glyph_id)` -- runs drawGlyph->encode->getExtents->reset, returns `EncodedGlyph` (caller owns blob)

**HarfBuzz GPU draw cycle** -- must follow exactly: `drawGlyph` -> `encode` (-> `Blob`) -> `getExtents` -> `reset`. Always `reset` after encode, even on error (`errdefer`).

**Glyph cache** -- `GlyphCache` maps `(font_id, glyph_id)` -> descriptor slot + pool allocation. Hot tier (ASCII + promoted): evicted only on font unload. Cold tier: LRU eviction via index-based doubly-linked list (O(1)). Promotion after `promote_frames` consecutive frames. On eviction, `DescriptorTable.nullSlot` writes a null descriptor before returning the slot -- requires `nullDescriptor` from `VK_EXT_robustness2`. Empty glyphs (e.g. space) get a null descriptor with no pool allocation.

**Pool allocator** -- `PoolAllocator` is a bump+freelist sub-allocator aligned to `minStorageBufferOffsetAlignment` (default 256).

**TextRenderer** -- `TextRenderer.init(ctx, color_format, allocator, options)` creates a renderer from a `VulkanContext`. Render loop: `begin()` -> `drawText(font, text, motor, color)` N times -> `flush(cmd_buf, proj, viewport)`.

## Shaders

**Compilation** -- `zig build shaders` -> `zig-out/shaders/*.spv` via `slangc`. Flags: `-profile spirv_1_6 -matrix-layout-column-major -I shaders`. The `exe` step depends on shaders. Slang compiles all entry points to `"main"` in SPIR-V regardless of source-level function name -- pipeline code must use `p_name = "main"`.

**Matrix layout** -- `-matrix-layout-column-major` matches Zig's column-major `[4][4]f32` upload. `float4x4(r0,r1,r2,r3)` constructor fills **rows**. `mul(m, v)` -> `OpVectorTimesMatrix(v, m)` in SPIR-V, which correctly computes M*v for column-major data. `m[row][col]` indexing.

**GPU struct generation** -- `zig build` runs `slangc -reflection-json` on `slug_task.slang`, then compiles and runs `tools/layout_gen.zig` to generate `extern struct` definitions (Slang->Zig type mapping: scalar, vector, matrix) as the `gpu_structs` module. `descriptors.zig` imports and re-exports these types. The shader is the single source of truth -- changing a Slang struct automatically updates the CPU-side types. Fields prefixed with `_` get zero defaults so callers don't need to set padding.

## Motor Math

`Motor` is a `[4]f32` extern struct (GPU ABI) representing a 2D PGA motor `[s, e12, e01, e02]`. SIMD internally via `@Vector(4,f32)`. Mirrors `shaders/pga.slang` layout. Key operations: `fromTranslation`, `fromRotation`, `fromRotationAbout`, `compose`, `composeTranslation` (optimized hot path), `apply`, `unitize`, `toMat`.

## Testing

**Test discovery** -- `src/root.zig` must `_ = @import(...)` each module in its `test` block for nested tests to run.

**Test assets** -- `assets/Inter-Regular.otf` (relative to project root). Do not hardcode system font paths.

**Integration tests** -- 8 cross-module integration tests in `src/root.zig` covering font pipeline (shape+encode, buffer reuse), cache+pool coordination (eviction, promotion, removeFont), and motor+font positioning (monotonic advance, composeTranslation equivalence, unitize drift recovery). All run without a live Vulkan device.

## Zig 0.16.0-dev Notes

- `b.addLibrary(.{ .linkage = .static })` -- `b.addStaticLibrary()` was removed
- `std.heap.DebugAllocator` -- `GeneralPurposeAllocator` was renamed
- `zig build test` is silent on success
