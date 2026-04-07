# CLAUDE.md

**heavy-slug** — Zig 0.16.0-dev GPU text renderer using the Slug algorithm (Eric Lengyel) for exact quadratic Bezier coverage via Vulkan `VK_EXT_mesh_shader`. Library: `src/root.zig`. Demo: `src/main.zig`.

## Commands

```bash
zig fmt src/                          # format
zig build                             # build lib + exe (also compiles shaders)
zig build run [-- args]               # run demo
zig build test                        # run tests (silent on success)
zig build shaders                     # compile Slang → SPIR-V only
zig build -Doptimize=ReleaseFast      # ReleaseSafe | ReleaseSmall | ReleaseFast
```

## Commits

`git commit -s -S` — Signed-off-by + GPG signature required. Always include:
```
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

## Architecture

```
src/
  root.zig            — public API re-exports
  main.zig            — demo executable
  font/
    ft.zig            — FreeType wrapper: Library, Face, rawHandle
    hb.zig            — HarfBuzz wrapper: Buffer, Font, GpuDraw, Blob
    glyph.zig         — FontContext (ft+hb+gpu_draw), EncodedGlyph
  gpu/
    context.zig       — VulkanContext, DeviceDispatch, InstanceDispatch, feature validation
    descriptors.zig   — GlyphCommand (64B), PushConstants (80B), SlotAllocator, DescriptorTable
    pool.zig          — PoolAllocator: bump+freelist sub-allocator for blob VkBuffer
    cache.zig         — GlyphCache: hot/cold two-tier LRU over descriptor slots
    pipeline.zig      — Mesh+fragment pipeline, embedded SPIR-V, dynamic rendering
    renderer.zig      — TextRenderer: init/deinit, loadFont, begin/drawText/flush
    layout.zig        — comptime validation: CPU structs vs GPU reflection
  math/
    pga.zig           — Cl(2,0,1) Motor/Point, @Vector(4,f32) SIMD internals
shaders/
  pga.slang           — Motor struct (mirrors pga.zig)
  slug_common.slang   — GlyphCommand, PushConstants, BlobReader
  slug_task.slang     — Task shader: frustum cull + mesh dispatch
  slug_mesh.slang     — Mesh shader: dilated quad per glyph
  slug_fragment.slang — Fragment shader: Slug band lookup + coverage
tools/
  layout_gen.zig      — build tool: slangc reflection JSON → GPU layout constants
```

`[Plan N]` = not yet implemented.

## Dependencies

| Key | Package | Purpose |
|-----|---------|---------|
| `vulkan` | Snektron/vulkan-zig | Vulkan bindings generator |
| `vulkan_headers` | KhronosGroup/Vulkan-Headers | `registry/vk.xml` |
| `freetype_src` | FreeType 2.14.3 | Font rasterization |
| `harfbuzz_src` | HarfBuzz 14.1.0 | Unicode shaping + HarfBuzz GPU |

Add/update: `zig fetch --save <url>` — hashes are pinned automatically.

## Key Patterns

**Vulkan bindings** — generated at build time from `vk.xml`:
```zig
const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
const vk_gen   = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
const vk_cmd   = b.addRunArtifact(vk_gen);
vk_cmd.addFileArg(registry);
const vulkan_zig = b.addModule("vulkan-zig", .{
    .root_source_file = vk_cmd.addOutputFileArg("vk.zig"),
});
```

**Vulkan filtered dispatch** — `vk.DeviceWrapper` does NOT exist. Use:
```zig
// Define struct with ?vk.PfnXxx = null fields, then:
vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch)
```
See `src/gpu/context.zig`.

**VulkanContext** — wraps a caller-provided `VkDevice`. Call `VulkanContext.checkDeviceSupport(physical_device, instance_dispatch)` before device creation to validate mesh shader + robustness2 support. Then `VulkanContext.init(physical_device, device, instance_dispatch, get_device_proc_addr)` loads the dispatch table and queries memory properties. `TextRenderer.initFromContext(ctx, ...)` is the convenience entry point. Required extensions: `VulkanContext.required_device_extensions`.

**C library builds** — `buildFreetype()` / `buildHarfbuzz()` in `build.zig` return `*std.Build.Step.Compile`. `@cImport` needs explicit `mod.addIncludePath()` — `linkLibrary` alone does not propagate headers.

**Cross-module cImport** — `ft.zig` and `hb.zig` each have independent `@cImport` blocks; Zig treats them as distinct type namespaces. Bridge `FT_Face` across modules via `*anyopaque`: `ft.Face.rawHandle()` returns `@ptrCast(self.handle.?)`, `hb.Font.createFromFtFace` reconstructs with `@ptrCast(@alignCast(ptr))`.

**Font pipeline** — `glyph.FontContext` owns FT_Face + hb_font + reusable hb_gpu_draw.
- `shapeText(text, null, null)` — auto-detect direction/script via `hb_buffer_guess_segment_properties`
- `encodeGlyph(glyph_id)` — runs drawGlyph→encode→getExtents→reset, returns `EncodedGlyph` (caller owns blob)

**HarfBuzz GPU draw cycle** — must follow exactly: `drawGlyph` → `encode` (→ `Blob`) → `getExtents` → `reset`. Always `reset` after encode, even on error (`errdefer`).

**Glyph cache** — `GlyphCache` maps `(font_id, glyph_id)` → descriptor slot + pool allocation. Hot tier (ASCII + promoted): evicted only on font unload. Cold tier: LRU eviction. Promotion after `promote_frames` consecutive frames. `PoolAllocator` is a bump+freelist sub-allocator aligned to `minStorageBufferOffsetAlignment`. On eviction, `DescriptorTable.nullSlot` writes a null descriptor before returning the slot — requires `nullDescriptor` from `VK_EXT_robustness2`.

**Motor math** — `[4]f32` extern struct (GPU ABI). SIMD internally via `@Vector(4,f32)`. Mirrors `shaders/pga.slang` layout: `[s, e12, e01, e02]`.

**Shader compilation** — `zig build shaders` → `zig-out/shaders/*.spv` via `slangc`. Flags: `-profile spirv_1_6 -matrix-layout-column-major -I shaders`. The `exe` step depends on shaders.

**Slang matrix layout** — `-matrix-layout-column-major` matches Zig's column-major `[4][4]f32` upload. `float4x4(r0,r1,r2,r3)` constructor fills **rows**. `mul(m, v)` → `OpVectorTimesMatrix(v, m)` in SPIR-V, which correctly computes M×v for column-major data. `m[row][col]` indexing.

**Test discovery** — `src/root.zig` must `_ = @import(...)` each module in its `test` block for nested tests to run.

**Layout validation** — `zig build` runs `slangc -reflection-json` on `slug_task.slang`, then compiles and runs `tools/layout_gen.zig` to emit GPU struct layout constants as a Zig module. `src/gpu/layout.zig` imports these constants and validates they match `descriptors.zig` at comptime via `@compileError`. Any Slang struct change that breaks the CPU/GPU ABI contract fails the build with a clear error message.

**Test assets** — `assets/Inter-Regular.otf` (relative to project root). Do not hardcode system font paths.

## Zig 0.16.0-dev Notes

- `b.addLibrary(.{ .linkage = .static })` — `b.addStaticLibrary()` was removed
- `@cImport` needs `mod.addIncludePath()` — `linkLibrary` alone doesn't propagate headers
- `zig build test` is silent on success
