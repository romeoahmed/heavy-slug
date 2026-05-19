# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This changelog summarizes user-visible and architectural changes. Fine-grained
implementation notes belong in commits and code review history.

## [Unreleased]

### Changed

- **Metal backend ABI tightened:** the Swift bridge draw entry now receives one
  versioned raw draw-request block instead of a long scalar parameter list,
  decodes and validates the ABI before touching Metal objects, and Zig-side
  Metal buffers now carry explicit sizes for resource writes, frame-parameter
  chunks, and glyph-pool uploads.
- **Vulkan backend refactored:** device requirement validation, host-coherent
  buffer allocation, and mesh draw planning now live in dedicated modules;
  `Context.requiredFeatureChain()` exposes the renderer feature pNext chain,
  `Context.init()` revalidates queried properties, and shader-object binding
  now explicitly clears unused vertex/tessellation/geometry/task stages before
  binding the linked no-task mesh/fragment pair.
- **Shader pipeline rewritten:** shared Slang math helpers and h-band candidate
  traversal now live in dedicated modules, fragment coverage explicitly gates
  candidate-index use before falling back to full scans, mesh emission planning
  is factored around a bounded NDC quad clip result, and the GPU ABI now names
  the eight-band candidate merge limit alongside mesh output budgets.
- **Core font/cache path rewritten:** font loading now has explicit
  FreeType pixel-size validation plus path and memory-backed `FontSource`
  handling, memory font bytes are owned by `LoadedFont` until after
  `FT_Done_Face`, HarfBuzz shape plans now guess missing segment properties
  even when callers provide only direction/script/language, and glyph-cache
  insertion now uses a single payload API backed by Zig 0.16 unmanaged hash
  maps.
- **Core outline/render path refactored:** outline regularization now separates
  cubic geometry, critical-point splitting, and quantization stability checks;
  renderer meshlet planning now lives outside `RendererCore`, precomputes
  viewport and dilation bounds once per glyph, and renderer options reject
  glyph capacities whose worst-case meshlet count overflows.
- **GPU ABI and mesh budget tightened:** `GlyphInstance` and `GlyphMeshlet`
  now carry only shader-read hot-path fields, per-meshlet records no longer
  duplicate glyph inverse matrices or CPU-only band indices, `src/gpu` now owns
  explicit mesh output/shared-memory budgets and resource binding indices, and
  Vulkan device validation now checks mesh output-memory limits in addition to
  workgroup, output count, component, shared-memory, and push-descriptor
  limits.
- **Coverage blob ABI rewritten:** glyph coverage blobs now use an explicit
  v3 32-bit word layout instead of serializing Zig struct memory, CPU decoding
  validates header invariants, curve bounds, contiguous CSR h-band tables, and
  sorted candidate IDs, and shader blob reads use the same named word offsets
  with an unsupported-magic guard.
- **Core byte pool allocator rewritten:** glyph blob pool metadata now uses
  stable free-block nodes, address-ordered coalescing, and power-of-two size
  bins instead of a single linear best-fit list; pool buffer sizes must now be
  aligned to the configured minimum storage alignment.
- **Core renderer contracts tightened:** renderer options now live in a
  dedicated core module with explicit validation for cache capacity, pool
  alignment, and blob-supported precision tiers; glyph-store initialization no
  longer depends back on `renderer_core.zig`, pool allocator initialization now
  returns typed errors for invalid capacity/alignment, and blob decoding
  validates band candidate ranges plus curve IDs before exposing table access.
  Blob-derived render bounds helpers now propagate decode errors instead of
  treating malformed blobs as unreachable.
- **CI Zig cache parsing fixed:** Zig package-cache setup now treats
  `zig env` output as Zig 0.16 object syntax rather than JSON on both Bash and
  PowerShell paths, and the quality gate exercises the parser against the real
  tool output.
- **CI automation hardened:** Windows jobs now enable Git long paths before
  checkout and system long paths immediately after checkout, the quality gate
  validates workflow/action YAML plus Bash and PowerShell scripts, and
  toolchain scripts use stricter native-command, retry, checksum, and cleanup
  behavior across runner images.
- **CI workflow architecture refactored:** the public GitHub Actions entrypoint
  now delegates to smaller reusable workflows for quality, core, shaders,
  Vulkan, and Metal; shared Zig/Slang setup and cache policy moved into local
  composite actions, and backend variants are grouped by platform to reduce
  check noise while preserving coverage.
- **CI dependency prefetch generalized:** Zig dependency prefetch now uses
  shared Bash and PowerShell retry scripts on every build runner image, while
  Windows-specific CI setup was reduced to enabling long paths before the
  normal cross-platform toolchain path.
- **Swift bridge style and linting tightened:** Swift/Metal bridge compilation
  now invokes `swiftc` through `xcrun --sdk macosx`, the build graph exposes
  `zig build swift-format-lint`, CI runs that strict Swift format lint on
  macOS, and Swift `@c` functions keep their C symbols while using Swift-style
  lower-camel identifiers internally.
- **Metal demo appearance host modernized:** the Cocoa/SwiftUI demo host now
  drives the explicit light/dark toggle through SwiftUI `preferredColorScheme`
  and an observable appearance model while continuing to set AppKit appearances
  for the native window/titlebar chrome.
- **Swift build toolchain resolution tightened:** Metal and Cocoa bridge builds
  now resolve `swiftc` and the macOS SDK through `xcrun --sdk macosx`, pass the
  SDK explicitly to Swift, fail early when the selected Swift compiler is older
  than `6.3`, and print the selected Apple Swift toolchain in CI Metal jobs.
- **Demo appearance policy unified:** all native demos now start from an
  explicit light color scheme and switch both rendered content and available
  native window chrome/client decorations only from the shared `B` key toggle
  instead of inheriting the system appearance.
- **Breaking naming contraction:** the public f64 affine type is now
  `Transform`, frame submission now takes `View`, the stale `Viewport` and
  `Affine2D64` exports were removed, render batch internals moved from
  `glyph_batch` to `frame_batch`, backend shape checks use `checkBackend`, and
  shader stats now use submitted-glyph/submitted-meshlet and meshlet-cull names.
  The unused public `GlyphKey` export was removed, backend stats access is now
  `Renderer.stats()`, and core debug stats use glyph/transform names instead of
  instance/affine leftovers.
- **Breaking build graph semantics:** `zig build` now builds and installs the
  backend-neutral static library instead of completing an empty install step;
  generated shader blobs, GPU reflection structs, and Vulkan generator output
  are private build imports rather than public package modules.
- **Build option semantics tightened:** `-Ddemo-backend=` is validated only
  when `-Ddemo=true`, explicit `-Dthinlto=on` now means "enable or fail"
  instead of being silently ignored in Debug mode, and the package manifest now
  includes the build helpers, native demos, docs, license, shaders, tools, and
  assets needed by the advertised build graph.
- **Breaking meshlet renderer path:** the required GPU path now uses a
  CPU-authored `GlyphMeshlet` stream plus mesh/fragment shaders, adds
  per-frame meshlet buffers to Vulkan and Metal, removes task payload expansion
  from the build outputs, and reduces mesh-to-fragment varyings to a flat
  meshlet index.
- **Vulkan mesh shader requirements narrowed:** the Vulkan backend no longer
  requires the task shader feature or task payload limits for the default
  renderer path; mesh workgroup dispatch count now equals the CPU meshlet
  count.
- **Vulkan Windows demo startup fixed:** the Vulkan shader-object path now
  creates mesh shader objects with explicit no-task usage, clears the vertex
  stage when binding mesh/fragment shader objects, and hardens swapchain
  extent, suboptimal-image, minimization, and present semaphore handling for
  native Win32 startup.
- **Mesh-only diagnostics cleaned up:** shader-stat counters and backend logs
  now report submitted glyphs, submitted meshlets, draw chunks, and meshlet-cull
  outcomes directly instead of preserving obsolete task-shader terminology.
- **Vulkan mesh limit validation tightened:** the Vulkan backend now validates
  mesh workgroup y/z dimensions and mesh shared-memory capacity in addition to
  mesh output counts before accepting a device.

- **Windows demo host hardened:** the Vulkan Win32 demo now embeds a modern
  Windows manifest for Per-Monitor-V2 DPI, long-path awareness, UTF-8 process
  code page, and Segment Heap, attaches window state during `WM_NCCREATE`,
  rounds DPI client sizing consistently, and clears captured input on focus or
  mode cancellation.
- **Windows demo host modernized:** the Win32 Vulkan demo now relies on the
  manifest-owned DPI contract, refreshes framebuffer dimensions from the client
  rect instead of packed size messages, updates scroll focus from documented
  screen-space wheel coordinates, handles queued quit messages, and applies
  best-effort Windows 11 DWM titlebar colors and rounded-corner preference.
- **Cocoa demo host modernized:** the Metal demo now uses AppKit backing
  coordinate conversion for `CAMetalLayer` drawable sizing, configures the
  layer-hosting view in documented order, routes mouse motion through an
  `NSTrackingArea`, maps keyboard input through AppKit characters instead of
  hardware key codes, and clears captured input on close, quit, focus loss,
  minimization, or app deactivation.
- **Breaking Swift Metal/Cocoa bridge rewrite:** the Objective-C++ bridge and
  C bridge headers were removed. The Metal backend and macOS demo host are now
  Swift `6.3` sources compiled by `swiftc` into Zig-linked objects, with Swift
  `@c` exports using only scalar values, pointers, pointer/length UTF-8 buffers,
  and explicit out parameters. The Cocoa host now exposes borrowed Metal objects
  through three out pointers and reports input snapshots through byte arrays
  plus field out pointers instead of C structs.
- **Swift bridge build contract tightened:** Swift bridge objects now compile
  with an explicit Apple Swift target triple derived from Zig's macOS target,
  require a macOS 26.0 or newer deployment target for Metal 4 APIs, and link
  Debug-only Swift support libraries only in Debug builds. The Cocoa `@c`
  entry points are plain C ABI functions that explicitly enter `MainActor`
  after validating the main-thread contract.
- **SwiftUI demo host path:** the macOS Metal demo now uses a SwiftUI
  `NSViewRepresentable` surface to host the `CAMetalLayer` while preserving the
  Zig-owned frame loop, AppKit menu/window behavior, and main-thread event
  polling contract.
- **Wayland demo GNOME 50 cleanup:** the Linux Vulkan host now binds
  GNOME 50/Mutter-compatible Wayland core versions plus the latest generated
  xdg-shell, viewporter, fractional-scale, and cursor-shape objects used by the
  demo, handles xdg-shell state/capability events, uses cursor-shape-v1 for
  compositor-owned pointer cursors, applies Adwaita-like client decoration
  geometry atomically with xdg configures, handles constrained/tiled/maximized/
  fullscreen edges, consumes high-resolution `wl_pointer.axis_value120` scroll
  events, and treats `wl_keyboard.key_state.repeated` as pressed.
- **Metal 4 backend tightened:** the Swift bridge now validates host
  device/queue/layer consistency up front, labels Metal 4 command resources,
  uses per-command residency for GPU-address argument table bindings, and keeps
  bridge geometry constants testable against the shared mesh ABI. The Metal
  backend intentionally keeps a mesh render pipeline state rather than adding
  dynamic libraries as a Shader Object analogue.
- **Metal/Cocoa Swift bridge rewritten:** the Metal bridge now retains
  host objects internally, validates buffer ownership before draws, submits both
  renderer resources and `CAMetalLayer` drawable residency sets with each
  Metal 4 command buffer, and uses explicit frame-slot reservation state. The
  Cocoa demo host was rewritten around the same main-thread SwiftUI/AppKit
  contract and Metal 4 layer residency requirement.
- **Breaking Vulkan shader-object backend:** the Vulkan renderer now requires
  `VK_EXT_shader_object`, creates linked mesh/fragment shader objects, and
  sets the required graphics state dynamically instead of creating a monolithic
  graphics pipeline. `heavy_slug_vulkan.Renderer.init` no longer takes a
  swapchain color format because attachment formats are not baked into shader
  object creation.
- **CI quality gates rewritten:** GitHub Actions now separate formatting,
  core tests, shader compilation, and backend/demo verification across Ubuntu,
  macOS, and Windows instead of hiding all behavior in one large test matrix.
- **CI toolchain setup tightened:** checkout credentials are not persisted,
  Zig/Slang tool caches are exact-version caches, Zig package caches are
  restored separately from build artifacts, and cache saves are limited to
  non-PR runs.
- **Windows CI hardened:** Windows jobs enable long paths before running tests,
  and Zig dependency prefetch uses the same bounded retry wrapper as the other
  runner images.
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
  `demo/common/input.zig`, keeping scene controls backend-independent.
- **Demo source boundary tightened:** demo entry points, shared scene code,
  native platform hosts, and demo-only Wayland C translation moved from `src/`
  to root-level `demo/`, keeping `src/` focused on library modules.
- **Shader build graph tightened:** Slang sources now use explicit Slang 2026
  modules, source-declared shader entries, stricter capability checks, and
  shared shader-stat constants.
- **Shader diagnostics expanded:** meshlet-cull reasons now use the normal
  `shader-stats` ABI and backend debug logs instead of ad hoc counters.
- **Breaking extreme-zoom precision contract:** renderer submission now uses a
  CPU f64 affine `View`; backend `Target` values no longer carry f32
  projection matrices; glyph blobs are 32-bit fixed-point and cache keys include
  the selected precision tier.
- **Reflection ABI generation hardened:** `tools/layout_gen.zig` now rejects
  conflicting layouts and emits generated layout tests for reflected GPU
  structs.
- **Font and bundled C library cleanup:** HarfBuzz/FreeType wrappers use
  Zig-style naming, report allocation failures more clearly, and build a
  slimmer outline-focused FreeType configuration.
- **Core cache internals tightened:** glyph promotion now happens without a
  fixed per-frame queue cap, deferred retirement compacts in one pass, and the
  byte pool reclaims tail frees to reduce fragmentation.

### Fixed

- **Renderer viewport meshlet clipping:** CPU-authored meshlet bounds now
  transform screen-space deltas with only the inverse affine linear part,
  preventing zoomed-out text from being clipped toward the lower-left viewport
  quadrant.
- **Demo zoom anchoring:** keyboard zoom now uses the framebuffer center as its
  screen-space anchor, and the Cocoa host reports mouse coordinates in backing
  pixels so scroll zoom matches the Metal drawable viewport.
- **Metal mesh-only pipeline validation:** the Metal backend now publishes and
  encodes a zero-sized object threadgroup when no object shader is present,
  matching Metal 4 mesh pipeline validation.
- **Fragment coordinate reconstruction fixed:** fragment `SV_Position` /
  Metal `[[position]]` is now converted from framebuffer coordinates back to
  the renderer's y-up screen space through explicit `FrameParams` ABI fields
  before analytic coverage evaluation.
- **Wayland demo protocol generation fixed:** the Linux Vulkan demo now uses a
  lazy pinned `wayland-protocols` 1.48 source dependency for generated protocol
  XML, generates the stable tablet-v2 stub required by cursor-shape-v1, and no
  longer depends on the system `wayland-protocols` XML version.
- **Extreme zoom glyph rendering fixed:** CPU f64 charts, meshlet-local anchors,
  integer h-band lookup, and saturated integer-relative shader decoding now
  avoid absolute-coordinate cancellation and unstable far-curve drops. Mesh
  viewport bounds now keep large fixed-point anchors in integer space, and
  shader-stats zero-coverage counters account for all fragment early exits.
- **CPU transform and fill-sign math corrected:** the public transform path is
  now affine f64, and cubic outline area uses an exact Bezier integral shared by
  blob fill-sign encoding.

### Removed

- **Obsolete render batch helper removed:** the old single-stream
  `core.render.GlyphBatch` helper was removed now that renderer submission
  always carries paired glyph and meshlet streams through `FrameBatch`.
- **ReleaseFast CI job removed:** release-mode build verification is no longer
  a separate GitHub Actions job.
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
  matches the Metal demo's clip-space and mouse controls.
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
  build logic moved into dedicated `src/core/`, `src/gpu/`, `src/backends/`,
  `demo/`, `shaders/`, and `build/` roots.
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
  shaders, 2D transforms, Slang shaders, generated GPU structs, an interactive
  demo, and tests.

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.2.0...v2.0.0
[1.2.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
