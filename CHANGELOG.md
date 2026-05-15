# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] - 2026-05-15

### Added

- **Metal 4 backend** (`src/metal/`): macOS renderer using Slang-generated Metal MSL, mesh shaders, an ObjC++ Metal bridge, external host objects, and triple-buffered submission.
- **Backend-neutral core renderer** (`src/render.zig`): shared text shaping, glyph encoding, cache/pool coordination, empty-glyph handling, and command generation used by Vulkan and Metal.
- **Demo-only Metal host** (`src/demo/metal_host.mm`): GLFW Cocoa window to Metal device, command queue, and `CAMetalLayer` setup without coupling the library backend to GLFW.
- **Zig 0.16 C translation modules** (`src/c/`): FreeType/HarfBuzz and GLFW declarations are translated from `build.zig` with `addTranslateC()`.
- **Configurable ThinLTO** (`-Dthinlto=auto|on|off`): release builds enable ThinLTO where Zig 0.16 can link it and expose an explicit hard-fail mode.

### Changed

- **Breaking:** Public API split into a lightweight `heavy_slug` core module plus opt-in `heavy_slug_vulkan` and `heavy_slug_metal` backend modules.
- **Breaking:** GPU contexts are externally supplied; core code no longer owns windowing or graphics-device creation.
- **Breaking:** Demo build selection is platform/backend explicit: `-Ddemo-backend=vulkan_spirv16` for Windows/Linux and `-Ddemo-backend=metal4` for macOS.
- **Vulkan renderer simplified** to use shared `TextCore`, reducing duplicated shaping, caching, and command encoding logic.
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

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
