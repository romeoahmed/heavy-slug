# CLAUDE.md

**heavy-slug** -- Zig 0.16.0-dev GPU text renderer using the Slug algorithm (Eric Lengyel) for exact quadratic Bezier coverage via Vulkan 1.4 `VK_EXT_mesh_shader`. Shaders compiled from Slang to SPIR-V 1.6. Library: `src/root.zig`. Demo: `src/main.zig`.

## Commands

```bash
zig fmt src/ tools/                    # format
zig build                              # build library (shaders + C deps)
zig build -Ddemo=true                  # build library + demo executable
zig build run -Ddemo=true [-- args]    # run demo
zig build test                         # run library + layout_gen tests
zig build test -Ddemo=true             # run all tests (library + demo)
zig build shaders                      # compile Slang -> SPIR-V only
zig build -Doptimize=ReleaseFast       # release build (ThinLTO on C deps)
```

`-Ddemo=false` (default) builds library only -- GLFW is not fetched or compiled. `-Ddemo=true` adds the demo executable, GLFW, run step, and demo tests. Release builds enable ThinLTO on C static libraries (FreeType, HarfBuzz, GLFW) for cross-language optimization. Zig executables cannot use LTO due to unresolved compiler-rt/musl symbols (`frexpf`, `isnan`, `__DENORM`, `wmemchr`, etc.) in the ThinLTO link pipeline (Zig 0.16.0-dev limitation, confirmed on `0.16.0-dev.3144`).

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
    descriptors.zig   -- DescriptorTable (batched writes), auto-generated GlyphCommand/PushConstants
    pool.zig          -- PoolAllocator: bump + sorted best-fit free-list with coalescing
    cache.zig         -- GlyphCache: hot/cold two-tier LRU, promotion queue, same-frame dedup
    pipeline.zig      -- Mesh+fragment pipeline, embedded SPIR-V, dynamic rendering
    renderer.zig      -- TextRenderer: init/deinit, loadFont, begin/drawText/flush, Stats
  math/
    pga.zig           -- Cl(2,0,1) Motor/Point, @Vector(4,f32) SIMD internals
  demo/
    glfw.zig          -- GLFW 3.4 wrapper with manual Vulkan externs
    vulkan.zig        -- Demo Vulkan bootstrap: instance, device, swapchain, frame sync
shaders/
  pga.slang           -- Motor struct (mirrors pga.zig)
  slug_common.slang   -- GlyphCommand, PushConstants, BlobReader, kTaskGroupSize
  slug_task.slang     -- Task shader: wave ballot compaction + dilation precompute
  slug_mesh.slang     -- Mesh shader: dilated quad from precomputed payload
  slug_fragment.slang -- Fragment shader: Slug band lookup + coverage
tools/
  layout_gen.zig      -- build tool: slangc reflection JSON -> extern struct definitions
```

**Demo** -- `src/main.zig` is an interactive text viewer (hb-gpu-demo style): pan, zoom, right-drag rotation with momentum, dark mode (B), reset (R), FPS counter. Requires GPU with `VK_EXT_mesh_shader`. ESC to exit.

## Dependencies

| Key | Package | Purpose |
|-----|---------|---------|
| `vulkan` | Snektron/vulkan-zig | Vulkan bindings generator |
| `vulkan_headers` | KhronosGroup/Vulkan-Headers 1.4.349 | `registry/vk.xml` |
| `freetype_src` | FreeType 2.14.3 | Font loading |
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

## Glyph Cache

`GlyphCache` maps `(font_id, glyph_id)` -> descriptor slot + pool allocation.

**Hot tier** -- ASCII + promoted glyphs. Evicted only on font unload. No LRU tracking (no linked-list node).

**Cold tier** -- LRU eviction via index-based doubly-linked list (O(1) touch/evict). On eviction, `DescriptorTable.nullSlot` writes a null descriptor before returning the slot -- requires `nullDescriptor` from `VK_EXT_robustness2`. Empty glyphs (e.g. space) get a null descriptor with no pool allocation.

**Promotion queue** -- `lookup()` appends to a bounded queue (max 64) when `consecutive_frames >= promote_frames`. `advanceFrame()` drains the queue (O(queue_length)) instead of scanning the entire HashMap. False-promotion guard: `consecutive_frames` is re-checked at drain time in case the streak broke between queuing and draining.

**Same-frame dedup** -- When `entry.last_frame == current_frame`, `lookup()` returns immediately without touching the LRU list or incrementing `consecutive_frames`. Eliminates redundant pointer writes for repeated characters within a frame.

## Descriptor Table

`DescriptorTable` manages bindless `VK_DESCRIPTOR_TYPE_STORAGE_BUFFER` descriptors for glyph blobs (binding 0, array of 64K) and the per-frame `GlyphCommand[]` buffer (binding 1).

**Batched writes** -- `updateSlot()`, `nullSlot()`, and `updateCommandBuffer()` enqueue writes into an inline pending buffer (max 256). `flushWrites()` commits all pending updates in a single `vkUpdateDescriptorSets` call. Auto-flushes if the buffer reaches capacity. Callers must call `flushWrites()` before any GPU work that reads the descriptors.

## Pool Allocator

`PoolAllocator` is a bump + sorted free-list sub-allocator for a contiguous byte pool (typically a large `VkBuffer`). All offsets aligned to `minStorageBufferOffsetAlignment` (default 256).

**Allocation** -- Best-fit scan over offset-sorted free list. Perfect fit removes the block; partial fit shrinks in-place. Falls back to bump allocation if no free block fits.

**Deallocation** -- Binary search for sorted insertion point, then coalesces with adjacent predecessor and/or successor blocks. Keeps the free list compact (typically 10-50 entries in steady state vs thousands without coalescing).

## TextRenderer

`TextRenderer.init(ctx, color_format, allocator, options)` creates a renderer from a `VulkanContext`. Render loop: `begin()` -> `drawText(font, text, motor, color)` N times -> `flush(cmd_buf, proj, viewport)`.

**Stats** -- Comptime-conditional `Stats` struct (`cache_hits`, `cache_misses`, `evictions`, `descriptors_flushed`, `glyphs_submitted`, `pool_free_blocks`). In `Debug` mode, counters are incremented per-frame and available via `stats.log()`. In `ReleaseFast` / `ReleaseSmall` / `ReleaseSafe`, `Stats` is an empty struct with no-op methods -- zero overhead.

## Shaders

**Compilation** -- `zig build shaders` -> `zig-out/shaders/*.spv` via `slangc`. Flags: `-profile spirv_1_6 -matrix-layout-column-major -I shaders -O2`. The task shader additionally requires `+spvGroupNonUniformBallot` for wave ballot intrinsics. Slang compiles all entry points to `"main"` in SPIR-V regardless of source-level function name -- pipeline code must use `p_name = "main"`.

**Shared constants** -- `slug_common.slang` defines `kTaskGroupSize = 32` (task/mesh workgroup size), `UNITS_PER_EM` / `INV_UNITS_PER_EM`, and `HEADER_LEN`. Both `slug_task.slang` and `slug_mesh.slang` import `slug_common` to keep `TaskPayload` array sizes in sync.

**Task shader** -- Wave ballot compaction (`WaveActiveCountBits` / `WavePrefixCountBits`) replaces serial `InterlockedAdd` atomics. Precomputes per-glyph dilation values (`motorScales`, `emPerPixels`) into the extended `TaskPayload` so the mesh shader avoids redundant `sqrt` ops.

**Mesh shader** -- Reads precomputed `emPerPixels[gid]` from the task payload instead of recomputing dilation locally. One workgroup = one glyph = 4 vertices + 2 triangles.

**Fragment shader** -- BlobReader uses `bitfieldExtract` for int16 unpacking and `* INV_UNITS_PER_EM` (reciprocal multiply) instead of division. `fwidth()` is deferred until after the zero-band early-out.

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
- `std.BoundedArray` was removed (ziglang/zig#24699) -- replacement is `std.ArrayListUnmanaged(T).initBuffer(&buf)` with `*Bounded` method variants, but `initBuffer` stores an absolute pointer so it is unsafe when the buffer and list are embedded in the same struct returned by value (pointer invalidated on copy). `cache.zig` uses a hand-rolled `BoundedQueue` that computes slices relative to `self` to avoid this
- `zig build test` is silent on success
