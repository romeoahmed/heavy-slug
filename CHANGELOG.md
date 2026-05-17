# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking font-wrapper cleanup:** HarfBuzz/FreeType Zig wrappers now use
  Zig-style `init`/`deinit`/`len` naming, shape buffer writes report allocation
  failures, and `hb.Font.fromFace()` takes a sized `ft.Face` instead of a raw
  `FT_Face` handle.
- **Bundled C library build tightened:** FreeType now uses generated
  outline-focused `ftmodule`/`ftoption` config headers, and HarfBuzz is built
  with the same bundled-FreeType feature macros its official Meson build would
  enable for variable coordinates and face transforms.

## [3.1.0] - 2026-05-17

### Changed

- **Vulkan frame bindings now use core 1.4 push descriptors** instead of
  frame-local descriptor pools, descriptor set allocation, and
  `vkUpdateDescriptorSets`.
- **Breaking cleanup:** `heavy_slug_vulkan.descriptors` is now
  `heavy_slug_vulkan.bindings`; the Vulkan helper types are renamed around
  their actual roles (`FrameBindings`, `BufferView`, `binding_writes`, and
  `binding_pushes`).
- **Vulkan pNext setup now uses reusable chain structs** for Vulkan 1.4,
  Vulkan 1.3, and `VK_EXT_mesh_shader` feature/property queries instead of
  open-coded chains in both backend and demo code.
- **Breaking cleanup:** `heavy_slug_metal.HostObjects` is now
  `heavy_slug_metal.Host`, and Zig-facing Metal bridge handles/buffers moved
  from `renderer.zig` into `context.zig`.
- **Vulkan demo host naming tightened** from generic graphics-context names to
  `Host`, `SwapchainFrame`, and `renderer_context`.

### Fixed

- **Vulkan demo orientation:** use a negative-height dynamic viewport so the
  shared demo projection and mouse controls match the Metal demo's y-up
  coordinate convention.
- **Vulkan demo build:** initialize Vulkan property/feature `pNext`
  chains with explicit `sType` values and zeroed payload structs so Zig 0.16
  bindings compile the demo path consistently.
- **Metal bridge teardown:** removed the extra in-flight boolean from frame
  slots; the bridge now drains frame-slot semaphores directly before teardown.

### Removed

- **Dead backend shim modules:** removed Vulkan/Metal `frame.zig` and
  `glyph_store.zig` re-export/resource-note modules; public backend types now
  come directly from each backend root.

## [3.0.0] - 2026-05-16

### Changed

- **Documentation refreshed:** `README.md` now front-loads Quick Start, adds a table of contents, compresses architecture/dependency details into tables, folds long command/API examples, and keeps `AGENTS.md` aligned with the current project rules.
- **Breaking naming cleanup:** shader build steps are now `zig build spirv` and `zig build msl`, demo backend values are `vulkan` and `metal`, and shader entry files use concise `task.slang`, `mesh.slang`, and `fragment.slang` names.
- **Breaking architecture refactor completed:** core public types, unit conversions, backend contracts, font/cache/render internals, and demo layout moved under the new `src/core/`, `src/gpu/`, `src/backends/`, and `src/demo/{common,vulkan,metal}/` structure now summarized in `README.md`.
- **Backend renderer API now exposes `Frame` and `Target` types** so demos submit text through an explicit begin/draw/submit frame boundary.
- **Backend frame submission now returns `FrameToken`** and glyph/resource retirement is deferred until the backend reports completed tokens.
- **Text submission now uses `TextRun`** on backend frames, and font loading uses `FontSource` plus `FontOptions`.
- **Renderer cleanup removed transitional `TextRenderer` and renderer-level `begin/drawText/flush` APIs**; backend modules now expose only `Renderer.beginFrame()`, `Frame.drawText()`, and `Frame.submit()`.
- **Top-level core exports narrowed** to stable public types; font internals and PGA math stay behind `heavy_slug.core.*` or private modules.
- **Slang sources are split into `shaders/core/` and `shaders/entries/`** so shared modules and entry points have distinct ownership.
- **Build logic split into `build/` modules** for dependency resolution, C libraries, shader compilation, backend modules, and demos.
- **Root compatibility aliases removed** for old font/cache/pool/render paths; consumers should use top-level public types or explicit `heavy_slug.core.*` modules.
- **README rewritten** as a richer canonical project overview with architecture, native cubic analytics, task/mesh shader culling, backend boundaries, platform dependency notes, diagnostics, CI, and explicit credit to the Slug algorithm.
- **Shader resource bindings split by backend** under `shaders/backend_vulkan/` and `shaders/backend_metal/`.
- **`GlyphStore` extracted** so cache metadata, byte-pool allocations, and deferred retirements have a single private owner.
- **Vulkan command storage is now frame-ring buffered** and protected by completed `FrameToken` tracking before slot reuse.
- **Vulkan glyph resources now use a single storage-buffer pool plus byte-offset `GlyphBlobRef` values** instead of per-glyph bindless storage-buffer descriptor slots.
- **Vulkan backend requirements simplified** to Vulkan 1.4 plus `VK_EXT_mesh_shader`; `VK_EXT_robustness2`, null descriptors, descriptor indexing, and update-after-bind are no longer required.
- **Metal backend migrated to the Metal 4 core API** with host-supplied `MTL4CommandQueue`, per-frame `MTL4CommandAllocator`, `MTL4Compiler` pipeline creation, and per-frame `MTL4ArgumentTable` resource binding.
- **Breaking:** `FontContext` was removed; font loading, shaping, and glyph encoding now live behind `FontSystem`, `LoadedFont`, `ShapePlan`, and `GlyphEncoder`.
- **Glyph encoding now owns its blob format** by using HarfBuzz draw callbacks directly instead of `hb_gpu_draw_encode`, then raising all outline primitives into cubic spans.
- **Cubic rendering regularized** by splitting cubic outlines at axis extrema and inflection points, preserving monotone control polygons after quantization, and using safeguarded Newton iteration with strict crossing tests in the fragment shader.
- **Glyph cache keys are variation-aware** with a reserved variation hash field for future variable-font instances.
- **CoverageBlob blobs gained an h-band candidate index** that accelerates common fragments while preserving the full-scan path as the correctness fallback.
- **CoverageBlob header simplified** by removing the unused blob version field and related decoder checks.
- **Glyph resource references are now typed as `GlyphBlobRef`** and the GPU command ABI uses backend-neutral `blob_ref` instead of Vulkan-specific descriptor naming.
- **Shader build steps now track Slang import files** so ABI reflection and compiled shaders regenerate when shared modules change.
- **Zig 0.16 API usage tightened** by replacing deprecated `std.ArrayListUnmanaged` aliases and old `std.mem.indexOf` calls.
- **CI expanded** to run tests and ReleaseFast builds on both `ubuntu-latest` and `macos-26`, including `-Dvulkan=true` on Ubuntu and `-Dmetal=true` on macOS ARM64.
- **Tool setup scripts hardened** to infer runner platforms, resolve Zig packages from the official download index, and match Slang release tarballs exactly.

### Removed

- **Legacy source roots** `src/font/`, `src/cache/`, `src/render.zig`, `src/vulkan/`, and `src/metal/`; consumers now use top-level public types or explicit `heavy_slug.core.*` modules.
- **Historical refactor planning docs** under `docs/`; the maintained architecture and algorithm overview now lives in `README.md`.
- **Repository-local VS Code settings** (`.vscode/`) so editor configuration stays user-local.
- **Unused Vulkan descriptor-slot allocator and descriptor limit validation** after the backend moved to single-pool glyph blob addressing.

## [2.0.0] - 2026-05-15

### Added

- **Metal 4 backend** (`src/backends/metal/`): macOS renderer using Slang-generated Metal MSL, mesh shaders, an ObjC++ Metal bridge, external host objects, and triple-buffered submission.
- **Backend-neutral core renderer** (`src/core/render/`): shared text shaping, glyph encoding, cache/pool coordination, empty-glyph handling, and command generation used by Vulkan and Metal.
- **Demo-only Metal host** (`src/demo/metal/`): GLFW Cocoa window to Metal device, command queue, and `CAMetalLayer` setup without coupling the library backend to GLFW.
- **Zig 0.16 C translation modules** (`src/c/`): FreeType/HarfBuzz and GLFW declarations are translated from `build.zig` with `addTranslateC()`.
- **Configurable ThinLTO** (`-Dthinlto=auto|on|off`): release builds enable ThinLTO where Zig 0.16 can link it and expose an explicit hard-fail mode.

### Changed

- **Breaking:** Public API split into a lightweight `heavy_slug` core module plus opt-in `heavy_slug_vulkan` and `heavy_slug_metal` backend modules.
- **Breaking:** GPU contexts are externally supplied; core code no longer owns windowing or graphics-device creation.
- **Breaking:** Demo build selection became platform/backend explicit for Windows/Linux Vulkan and macOS Metal paths.
- **Vulkan renderer simplified** to use shared renderer core logic, reducing duplicated shaping, caching, and command encoding logic.
- **Glyph cache eviction made current-frame safe** so pool storage referenced by the frame being assembled is not reused prematurely.
- **Build graph cleaned up** so `vulkan`, `vulkan_headers`, and `glfw_src` remain lazy, and FreeType/HarfBuzz dependencies are resolved once.
- **CI rewritten** with repository scripts for configurable Zig and Slang versions plus layered caching for tools, global Zig packages, and local build artifacts.
- **Documentation rewritten** for the 2.0 architecture; `README.md` and `AGENTS.md` now describe core/backend boundaries and current commands.

### Removed

- **Source-level `@cImport` blocks** in Zig modules; C imports now live in build-system translation modules.
- **`CLAUDE.md`** project guidance; `AGENTS.md` is now the repository contributor and agent guide.
- **Hard GLFW dependency outside demos**; library and backend modules no longer require GLFW.

### Fixed

- **Slang SPIR-V profile warning** by declaring required group non-uniform capabilities explicitly.
- **macOS release ThinLTO behavior** by skipping unsupported Mach-O ThinLTO in `auto` mode and reporting a clear error in `on` mode.

## [1.2.0] - 2026-04-12

### Added

- **Debug stats** (`renderer.zig`): comptime-conditional `Stats` struct tracking cache hits/misses, evictions, descriptor flushes, glyphs submitted, and pool free blocks per frame -- zero overhead in release builds.
- **Promotion queue** (`cache.zig`): bounded queue populated during `lookup()`, drained in `advanceFrame()` -- replaces O(cache_size) full HashMap scans.
- **Same-frame dedup** (`cache.zig`): `lookup()` short-circuits on repeated access within the same frame, eliminating redundant LRU list mutations.
- **Shared shader constants** (`slug_common.slang`): task/mesh workgroup size and reciprocal units-per-em constants are shared by shader stages.

### Changed

- **Descriptor writes batched** (`descriptors.zig`): descriptor updates are accumulated and flushed in fewer Vulkan API calls.
- **Pool allocator rewritten** (`pool.zig`): offset-sorted free-list with best-fit allocation and adjacent-block coalescing on `free()`.
- **Task shader optimized** with wave ballot compaction and precomputed payload values.
- **Mesh/fragment shader math optimized** by reducing repeated dilation and dequantization work.
- **Documentation expanded** to cover performance architecture and build constraints.

### Fixed

- **False promotion guard**: promotion queue entries are rechecked before promotion.
- **`descriptors_flushed` stat**: multi-flush frames now accumulate correctly.

## [1.1.0] - 2026-04-10

### Added

- **MIT license** and initial `README.md`.
- **GitHub Actions CI** for formatting, tests, and release builds.
- **ThinLTO** on C static libraries in release builds where supported.

### Changed

- **Vulkan-Headers** updated to 1.4.349.
- **GLFW** dependency switched to the official zip release artifact.
- **`-Ddemo` build flag** defaults to `false` so library consumers avoid demo dependencies.
- **`build.zig` reorganized** into clearer build sections.

## [1.0.0] - 2026-04-09

### Added

- Initial core Slug text renderer with FreeType, HarfBuzz, Vulkan mesh shaders, PGA motor math, Slang shaders, generated GPU structs, interactive demo, Wayland GLFW support, and unit/integration tests.

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
