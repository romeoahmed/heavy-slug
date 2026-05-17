# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog summarizes user-visible and architectural changes. Fine-grained
implementation notes belong in commits and code review history.

## [Unreleased]

### Changed

- **Documentation refreshed:** `README.md`, `AGENTS.md`, and `CHANGELOG.md`
  now describe the current native-demo-host architecture at a higher level and
  remove stale or overly specific platform implementation notes.
- **Breaking demo host rewrite:** demos no longer depend on GLFW. The Vulkan
  demo now uses native Win32 on Windows and Wayland xdg-shell on Linux; the
  Metal demo uses native Cocoa and a direct `CAMetalLayer` host.
- **Vulkan demo platform handling changed:** demo hosts load the system Vulkan
  loader at runtime and create native Win32 or Wayland Vulkan surfaces directly.
- **Windows demo modernized:** the Win32 host keeps per-monitor DPI behavior,
  native system commands, and optional DWM dark-titlebar integration aligned
  with the demo scene.
- **Wayland demo modernized:** the Linux host now uses xdg-shell, viewporter,
  and fractional-scale-v1, renders buffers at compositor-preferred scale, and
  keeps a client-side decoration path for compositors that do not provide
  server-side decorations.
- **macOS demo chrome cleaned up:** the Cocoa demo keeps native window chrome,
  installs normal app menu actions, and routes close/quit shortcuts through the
  same graceful shutdown path.
- **Shared demo input extracted:** native hosts translate platform input into
  `src/demo/common/input.zig`, keeping scene controls backend-independent.
- **Shader build graph tightened:** Slang sources now use explicit Slang 2026
  modules, source-declared shader entries, stricter capability checks, and
  shared shader-stat constants.
- **Reflection ABI generation hardened:** `tools/layout_gen.zig` now rejects
  conflicting layouts and emits generated layout tests for reflected GPU
  structs.
- **Font and bundled C library cleanup:** HarfBuzz/FreeType wrappers use
  Zig-style naming, report allocation failures more clearly, and build a
  slimmer outline-focused FreeType configuration.

### Removed

- **GLFW dependency removed:** the `glfw_src` package, translated GLFW header,
  and demo GLFW wrapper/build path were deleted.
- **Wayland xdg-decoration path removed:** the Linux demo now keeps CSD as the
  single decoration path.

## [3.1.0] - 2026-05-17

### Changed

- **Vulkan frame bindings now use core 1.4 push descriptors** instead of
  frame-local descriptor pools and descriptor-set allocation.
- **Breaking Vulkan naming cleanup:** `heavy_slug_vulkan.descriptors` became
  `heavy_slug_vulkan.bindings`, with helper names aligned around
  `FrameBindings` and `BufferView`.
- **Vulkan pNext setup centralized** in reusable chain structs for Vulkan 1.4,
  Vulkan 1.3, and mesh-shader feature/property queries.
- **Breaking Metal naming cleanup:** `heavy_slug_metal.HostObjects` became
  `heavy_slug_metal.Host`, and bridge-facing handles moved into
  `src/backends/metal/context.zig`.
- **Vulkan demo host names tightened** around `Host`, `SwapchainFrame`, and
  `renderer_context`.

### Fixed

- **Vulkan demo orientation:** the demo now uses a y-up dynamic viewport that
  matches the Metal demo's projection and mouse controls.
- **Vulkan demo build stability:** feature/property chains are initialized with
  explicit payloads for Zig 0.16 bindings.
- **Metal bridge teardown:** frame-slot synchronization is drained directly
  before teardown.

### Removed

- **Dead backend shim modules removed:** backend public types now come directly
  from each backend root.

## [3.0.0] - 2026-05-16

### Changed

- **Documentation refreshed:** `README.md` became the maintained architecture
  overview, with aligned contributor guidance in `AGENTS.md`.
- **Breaking source layout refactor:** core, GPU, backend, demo, shader, and
  build logic moved into the current `src/core/`, `src/gpu/`,
  `src/backends/`, `src/demo/`, `shaders/`, and `build/` structure.
- **Breaking renderer API cleanup:** backends now expose explicit
  `Renderer.beginFrame()`, `Frame.drawText()`, and `Frame.submit()` flow with
  `FrameToken`-based retirement.
- **Public core exports narrowed** to stable value types, with internals kept
  behind explicit module boundaries.
- **Vulkan backend resource model simplified** to a single glyph blob buffer
  addressed by byte-offset `GlyphBlobRef` values.
- **Vulkan backend requirements simplified** to Vulkan 1.4 plus mesh shader
  support, dynamic rendering, and push descriptors.
- **Metal backend migrated to Metal 4** with host-supplied objects and
  bridge-owned pipeline/resource submission.
- **Glyph encoding moved in-house** through HarfBuzz draw callbacks, cubic
  normalization, regularization, and coverage blob generation.
- **Coverage blobs gained an h-band candidate index** while preserving the
  full-scan correctness fallback.
- **Shader build and ABI reflection improved** so shared shader imports and
  reflected GPU structs regenerate consistently.
- **CI expanded** across Ubuntu and macOS for core, backend, shader-stat, and
  ReleaseFast coverage.

### Removed

- **Legacy source roots removed:** old `src/font/`, `src/cache/`,
  `src/render.zig`, `src/vulkan/`, and `src/metal/` paths were replaced by the
  current module structure.
- **Historical planning docs removed:** the maintained overview now lives in
  `README.md`.
- **Unused Vulkan descriptor-slot machinery removed** after the glyph pool
  switched to byte-offset addressing.

## [2.0.0] - 2026-05-15

### Added

- **Metal 4 backend:** macOS rendering path using Slang-generated Metal
  shaders, mesh rendering, and an Objective-C++ bridge.
- **Backend-neutral renderer core:** shared shaping, glyph encoding, cache
  coordination, and command generation for Vulkan and Metal.
- **Demo-only Metal host:** a Cocoa/Metal demo path without coupling core or
  backends to windowing code.
- **Build-system C translation modules:** FreeType, HarfBuzz, and demo C
  declarations moved out of source-level `@cImport`.
- **Configurable ThinLTO:** `-Dthinlto=auto|on|off` for release builds.

### Changed

- **Breaking public API split:** `heavy_slug` became the lightweight core
  module; Vulkan and Metal became opt-in backend modules.
- **Breaking ownership cleanup:** applications now supply GPU contexts and
  platform objects instead of the library owning them.
- **Demo backend selection became explicit** for Windows/Linux Vulkan and
  macOS Metal paths.
- **Vulkan renderer adopted the shared renderer core**, reducing duplicated
  shaping, cache, and command encoding logic.
- **Glyph cache eviction became current-frame safe** through explicit frame
  retirement.
- **CI was rewritten** with repository setup scripts and layered tool/build
  caching.
- **Documentation rewritten** for the core/backend boundary.

### Removed

- **Source-level `@cImport` blocks removed** in favor of build-system
  translation modules.
- **`CLAUDE.md` removed**; `AGENTS.md` is the repository contributor and agent
  guide.
- **Hard GLFW dependency outside demos removed**; library and backend modules
  no longer require GLFW.

### Fixed

- **Slang SPIR-V profile warning fixed** by declaring required capabilities.
- **macOS ThinLTO behavior clarified** for Zig 0.16 Mach-O targets.

## [1.2.0] - 2026-04-12

### Added

- **Debug stats:** renderer diagnostics for cache activity, glyph submission,
  pool state, and descriptor work.
- **Promotion queue:** bounded cache promotion path replacing full map scans.
- **Same-frame dedup:** repeated cache lookups in one frame avoid redundant LRU
  mutations.
- **Shared shader constants** for task/mesh workgroup sizing.

### Changed

- **Descriptor writes batched** to reduce Vulkan update overhead.
- **Pool allocator rewritten** with best-fit allocation and adjacent-block
  coalescing.
- **Task, mesh, and fragment shaders optimized** to reduce redundant work.
- **Documentation expanded** around performance architecture and build
  constraints.

### Fixed

- **Promotion guard corrected** so stale promotion entries are rechecked.
- **Descriptor flush stats fixed** for multi-flush frames.

## [1.1.0] - 2026-04-10

### Added

- **MIT license** and initial `README.md`.
- **GitHub Actions CI** for formatting, tests, and release builds.
- **ThinLTO support** for C static libraries where supported.

### Changed

- **Vulkan Headers updated** to 1.4.349.
- **GLFW dependency switched** to the official release artifact.
- **Demo builds became opt-in** through `-Ddemo=false` by default.
- **`build.zig` reorganized** into clearer build sections.

## [1.0.0] - 2026-04-09

### Added

- Initial Slug-inspired Vulkan text renderer with FreeType, HarfBuzz, mesh
  shaders, PGA transforms, Slang shaders, generated GPU structs, an interactive
  demo, and tests.

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
