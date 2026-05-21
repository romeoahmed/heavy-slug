# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog is for users upgrading the library or demos. Fine-grained
implementation history belongs in commits and code review notes.

## [Unreleased]

### Added

- **Demo metrics overlay:** the shared demo scene now renders a
  backend-neutral screen-space readout for FPS, relative view zoom, and native
  display scale.
- **Direct-present demo surface contract:** Vulkan demos now model platform
  presentation as a direct WSI swapchain path. Wayland binds
  linux-dmabuf-v1 feedback when advertised; Windows documents that DXGI shared
  handles and NT sections are outside the Vulkan HWND swapchain path.
- **Swift formatting gate:** `zig build swift-format-lint` runs
  `swift format lint --strict` for the Swift bridge and Cocoa demo sources.
- **Cross-runner Zig dependency prefetch:** Bash and PowerShell retry wrappers
  are shared by all CI runner images instead of being Windows-only.

### Changed

- **Breaking project architecture modernization:** the library now has a strict
  core/backend/demo boundary, native demo hosts instead of GLFW, opt-in Vulkan
  and Metal modules, private generated shader/blob modules, and a build graph
  that installs the backend-neutral core library by default.
- **Core renderer, cache, and font pipeline rewritten:** `RendererCore` owns
  shared shaping, glyph encoding, cache metadata, byte-pool retirement, and
  meshlet batch planning; font loading supports path and copied memory sources;
  HarfBuzz plans guess missing segment properties; renderer options validate
  capacity, storage alignment, and precision policy before allocation.
- **Coverage blob ABI rewritten:** `CoverageBlob` is now an explicit 32-bit word
  stream with separate `HSBL` magic and `4.0` protocol version words. CPU decode
  validates headers, curve bounds, CSR h-band tables, sorted candidate IDs, and
  unsupported versions before upload.
- **Core math and high-zoom path tightened:** public transforms use f64
  `Transform`/`View`, precision tiers are selected from CPU affine charts, and
  extreme zoom rendering avoids f32 absolute-coordinate cancellation through
  meshlet-local anchors and integer-relative shader decoding.
- **GPU ABI and shader pipeline rewritten:** shared Slang 2026 modules now own
  coverage, h-band traversal, chart mapping, stats, mesh clipping, and backend
  resource shims; generated Zig GPU structs are reflection-derived with
  size/offset tests; the required render path is CPU-authored meshlets plus
  mesh/fragment shaders.
- **Outline coverage contract tightened:** meshlet planning now describes
  pixel-center support domains, shader geometry decode requires explicit
  `2^24`-radius relative exactness instead of Bezier control-point clamping,
  and the fast fill path is documented for valid font glyph outlines rather
  than arbitrary self-intersecting vector paths.
- **Vulkan backend modernized:** the backend requires Vulkan 1.4 with mesh
  shaders, shader objects, dynamic rendering, push descriptors, and checked
  mesh limits; device requirement validation, pNext chains, buffer allocation,
  frame bindings, shader-object state, and mesh draw planning are split into
  dedicated modules.
- **Metal backend rewritten in Swift:** Objective-C++ bridge code and C bridge
  headers were removed. Swift 6.3 `@c` entry points use scalar/pointer ABI
  values, explicit status/out-handle results, diagnostics buffers, and
  protocol-versioned raw request blocks. Zig mirrors the bridge from
  `src/backends/metal/context.zig`.
- **Build graph rewritten:** build options expose derived backend/demo needs,
  Vulkan packages and Wayland protocol XML are lazy, shader artifacts are cached
  inside the configure graph, Swift toolchain resolution happens once per Metal
  build, and cross-target test run steps skip foreign execution after compile
  success.
- **Native demo hosts rewritten:** Windows uses a titled Windows 11 native
  host with per-monitor DPI, DWM titlebar theming, a modern manifest, and
  selected ntdll/win32u calls; Wayland uses a GNOME-oriented xdg-shell CSD path
  with fractional-scale, viewporter, cursor-shape, and title painting; macOS
  uses SwiftUI/AppKit with native menus, normal window chrome, and a
  `CAMetalLayer`.
- **Vulkan demo host rewritten:** WSI dispatch, physical-device selection,
  surface planning, swapchain image state, synchronization2 transitions,
  acquire/present fencing, and renderer-aligned frame slots now live in an
  explicit state machine using the current Vulkan WSI path.
- **Demo appearance policy unified:** all native demos start from an explicit
  light appearance and use `B` to toggle light/dark rendering and available
  native chrome instead of following the system setting.
- **Demo sample content changed:** native demos now use `NotoSansJP-Regular.otf`
  and multilingual Latin, Japanese, Chinese, Cyrillic, Greek, and accented
  Latin text instead of the old Inter/Lorem Ipsum sample.
- **CI architecture refactored:** the public CI workflow is now a small
  orchestrator over reusable quality, core, shader, Vulkan, and Metal
  workflows. Composite actions own Zig/Slang setup, cache restore/save, and
  dependency prefetch behavior.
- **Documentation repositioned:** `README.md` is now a human-facing
  architecture/API/quick-start document; `AGENTS.md` is the operational guide
  for coding agents; this changelog is consolidated by user-visible change
  area instead of commit-by-commit notes.

### Fixed

- **Vulkan demo window titles:** Win32 and Wayland demo titles now share strict
  UTF-8 validation, reject embedded NUL truncation, and keep Wayland's
  client-drawn headerbar from byte-rendering unsupported Unicode.
- **Vulkan Windows demo startup:** mesh shader objects are created and bound
  with the no-task path, unused shader-object stages are cleared, and swapchain
  extent, minimized-window, suboptimal-image, and present-semaphore handling are
  hardened.
- **Renderer viewport clipping:** CPU meshlet bounds now transform
  screen-space deltas with the inverse affine linear part, avoiding lower-left
  clipping drift at zoomed-out scales.
- **Fragment coordinate reconstruction:** shaders convert framebuffer
  `SV_Position` / `[[position]]` coordinates back into y-up renderer space
  through explicit frame parameters before analytic coverage evaluation.
- **Metal mesh-only validation:** Metal now encodes the zero-sized object
  threadgroup required for a mesh-only pipeline.
- **Wayland protocol generation:** generated protocol XML comes from the lazy
  pinned `wayland-protocols` source dependency, including the stable tablet-v2
  stub required by cursor-shape-v1.
- **CI Zig cache parsing:** Bash and PowerShell setup paths parse real Zig 0.16
  `zig env` object syntax instead of assuming JSON.
- **CPU transform and fill-sign math:** affine transform behavior and cubic
  outline area integration are tested and aligned with the blob fill-sign path.
- **Analytic outline edge cases:** CPU meshlets now include left/top/bottom
  half-pixel support and scan neighboring h-bands for slice influence; cubic
  regularization now reports `PrecisionUnsupported` instead of silently
  accepting an unproven span at the subdivision depth cap.

### Removed

- **GLFW demo dependency removed:** demos are now native Win32, Wayland, and
  SwiftUI/AppKit hosts.
- **Objective-C++ bridge removed:** Metal backend and Cocoa demo bridge code are
  Swift sources compiled by `swiftc`.
- **Task-shader renderer path removed:** the current renderer dispatches
  CPU-authored meshlet work directly to mesh/fragment shaders.
- **Legacy Vulkan descriptor model removed:** per-glyph descriptor slots,
  frame-local descriptor pools, descriptor-set allocation, and descriptor
  indexing as glyph addressing are not part of the current backend.
- **Wayland xdg-decoration fallback removed:** the Linux demo keeps
  client-side decorations as the single path.
- **Inter demo font removed:** `assets/Inter-Regular.otf` was replaced by
  `assets/NotoSansJP-Regular.otf`.
- **Stale public names removed:** old viewport/affine/glyph-batch/debug-stat
  names were contracted around `Transform`, `View`, `FrameBatch`,
  `GlyphBlobRef`, and submitted glyph/meshlet terminology.

## [3.1.0] - 2026-05-17

### Changed

- Vulkan frame bindings switched to Vulkan 1.4 push descriptors.
- Vulkan pNext feature/property setup moved into reusable chain structs.
- Backend public names were tightened around `FrameBindings`, `BufferView`,
  and Metal `Host`.

### Fixed

- Vulkan demo viewport orientation now matches the Metal demo.
- Vulkan demo feature/property initialization is stable with Zig 0.16
  bindings.
- Metal bridge teardown drains frame-slot synchronization directly.

### Removed

- Dead backend shim modules were removed from the public backend surface.

## [3.0.0] - 2026-05-16

### Changed

- Source layout was split into `src/core/`, `src/gpu/`, `src/backends/`,
  `demo/`, `shaders/`, and `build/`.
- Backend renderers adopted the explicit `Renderer.beginFrame()`,
  `Frame.drawText()`, `Frame.submit()`, and `FrameToken` retirement flow.
- Core exports were narrowed to stable value types and renderer options.
- Vulkan moved to a single glyph-pool buffer addressed by byte-offset
  `GlyphBlobRef` values.
- Metal moved to the Metal 4 host-object model.
- Glyph encoding moved in-house through HarfBuzz outline callbacks,
  regularization, and coverage blob generation.
- Shader build and ABI reflection were hardened around shared Slang imports.

### Removed

- Legacy `src/font/`, `src/cache/`, `src/render.zig`, `src/vulkan/`, and
  `src/metal/` roots were replaced by the current module structure.
- Historical planning docs were removed in favor of the maintained README.
- Unused Vulkan descriptor-slot machinery was removed.

## [2.0.0] - 2026-05-15

### Added

- Metal backend and demo path for macOS.
- Backend-neutral renderer core shared by Vulkan and Metal.
- Build-system C translation modules for FreeType, HarfBuzz, and demo C
  declarations.
- Configurable `-Dthinlto=auto|on|off`.

### Changed

- Public API split into default `heavy_slug` core plus opt-in backend modules.
- Applications became responsible for GPU contexts and platform objects.
- Demo backend selection became explicit.
- Glyph cache eviction became frame-token safe.
- CI and documentation were rewritten for the new core/backend boundary.

### Removed

- Source-level `@cImport` blocks were replaced by build-system translation
  modules.
- `CLAUDE.md` was replaced by `AGENTS.md`.
- Hard GLFW coupling outside demos was removed.

### Fixed

- Slang SPIR-V profile warnings were fixed by declaring required capabilities.
- macOS ThinLTO behavior was clarified for Zig 0.16 Mach-O targets.

## [1.2.0] - 2026-04-12

### Added

- Debug renderer statistics for cache activity, glyph submission, pool state,
  and descriptor work.
- Cache promotion queue and same-frame lookup deduplication.
- Shared shader constants for task/mesh workgroup sizing.

### Changed

- Descriptor writes were batched.
- Pool allocation and shader hot paths were optimized.
- Documentation expanded around performance architecture and build constraints.

### Fixed

- Promotion revalidation and descriptor flush statistics were corrected.

## [1.1.0] - 2026-04-10

### Added

- MIT license and initial README.
- GitHub Actions CI for formatting, tests, and release builds.
- ThinLTO support for bundled C static libraries where supported.

### Changed

- Vulkan Headers updated to 1.4.349.
- GLFW dependency switched to the official release artifact.
- Demo builds became opt-in.
- `build.zig` was reorganized into clearer build sections.

## [1.0.0] - 2026-04-09

### Added

- Initial Slug-inspired Vulkan text renderer with FreeType, HarfBuzz, mesh
  shaders, 2D transforms, Slang shaders, generated GPU structs, an interactive
  demo, and tests.

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
