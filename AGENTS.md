# Repository Guidelines

## Purpose

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines with FreeType, encodes precision-tiered cubic coverage blobs, and
renders through mesh and fragment shaders on Vulkan 1.4 and Metal 4.

This file is for AI coding agents and maintainers executing changes in the
repository. Keep `README.md` human-facing and concise. Keep `CHANGELOG.md`
user-visible and consolidated. Put agent workflow details here.

## Non-Negotiable Boundaries

- Core code must not own a GPU context, command queue, command buffer,
  swapchain, surface, window, `CAMetalLayer`, or window-toolkit object.
- Applications own platform and graphics lifetimes. Backends adapt
  application-owned objects to heavy-slug rendering.
- Do not add GLFW, SDL, Qt, Windows App SDK, or another toolkit to the native
  demo path unless an explicit architecture decision changes the project model.
- Preserve the single glyph-pool buffer model unless profiling proves a better
  replacement. Glyph addressing uses byte-offset `GlyphBlobRef` values.
- GPU layouts are generated from Slang reflection. Do not hand-edit generated
  ABI structs or duplicate reflected layout constants manually.
- Keep build-system C translation in `build/` through `addTranslateC()`.
  Do not reintroduce source-level `@cImport`.
- Do not commit generated artifacts from `zig-out/`, `.zig-cache/`, or
  `zig-pkg/`.

## Project Map

- `src/root.zig`: public `heavy_slug` core module.
- `src/core/`: public value types plus font, outline, blob, cache, and
  renderer-core internals.
- `src/gpu/`: backend-neutral resource model, mesh limits, ABI provenance, and
  shader stats.
- `src/backends/vulkan/`: opt-in `heavy_slug_vulkan` backend.
- `src/backends/metal/`: opt-in `heavy_slug_metal` backend and Swift bridge.
- `src/c/`: core C headers translated by the build graph.
- `demo/common/`: demo-only scene and input helpers.
- `demo/vulkan/`: Windows/Linux Vulkan demo entry and WSI/device host logic.
- `demo/metal/`: macOS Metal demo entry.
- `demo/platform/`: native Win32, Wayland, and Cocoa hosts.
- `shaders/core/`: shared Slang 2026 ABI, stats, h-band, chart, and coverage
  logic.
- `shaders/backend_vulkan/`, `shaders/backend_metal/`: backend resource shims.
- `shaders/entries/`: `mesh.slang` and `fragment.slang`.
- `tools/layout_gen.zig`: Slang reflection to Zig extern structs.
- `build/`: modular Zig build helpers.
- `.github/`: reusable GitHub Actions workflows, composite actions, and
  Bash/PowerShell setup scripts.

## Public API Surface

The default package module is `heavy_slug`. Stable top-level exports are:

- `FontSource`, `FontOptions`, `FontHandle`
- `TextRun`
- `Color`, `Transform`, `View`
- `PrecisionPolicy`, `FillRule`
- `RendererOptions`, `FrameToken`, `ShaderStats`

Backend modules expose `Context`, `Renderer`, `Frame`, `Target`,
`RendererOptions`, `FontHandle`, `FrameToken`, `Stats`, and
`shader_stats_enabled`. Vulkan also exposes `required_api_version`,
`required_device_extensions`, and `Context.requiredFeatureChain()`. Metal also
exposes `Host` for borrowed `id<MTLDevice>`, `id<MTL4CommandQueue>`, and
`CAMetalLayer *` objects.

When changing any of these names, argument contracts, build options, shader ABI
fields, protocol words, backend requirements, or diagnostics, update
`README.md` and `CHANGELOG.md`.

## Build Commands

- `zig build`: build and install the backend-neutral static library.
- `zig build test`: run core and build-tool tests.
- `zig build test -Dvulkan=true`: build and test the Vulkan backend.
- `zig build test -Dmetal=true`: build and test the Metal backend on macOS.
- `zig build test -Dvulkan=true -Dshader-stats=true`: test Vulkan shader
  counter bindings.
- `zig build test -Dmetal=true -Dshader-stats=true`: test Metal shader counter
  bindings.
- `zig build test -Ddemo=true -Ddemo-backend=vulkan`: build and test the
  Windows/Linux Vulkan demo host path.
- `zig build test -Ddemo=true -Ddemo-backend=metal`: build and test the macOS
  Metal demo host path.
- `zig build spirv`: compile Slang to SPIR-V 1.6.
- `zig build msl`: compile Slang to Metal Shading Language.
- `zig build swift-format-lint`: run strict Swift format lint through
  `xcrun --sdk macosx`.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan`: run the Vulkan demo.
- `zig build run -Ddemo=true -Ddemo-backend=metal`: run the Metal demo.
- `zig build -Doptimize=ReleaseFast [-Dthinlto=auto|on|off]`: release build;
  `auto` enables ThinLTO only where Zig 0.16 can link it.

Run the narrowest verification that covers a change, then broaden when touching
shared contracts. Public API, shader ABI, backend resource binding, and demo
platform changes normally require the matching backend and shader-stat variants
where the host platform supports them.

## Dependency Rules

- All platforms require Zig `0.16.0`.
- FreeType `2.14.3` and HarfBuzz `14.2.0` are pinned source dependencies in
  `build.zig.zon` and are built statically. Do not require system FreeType or
  HarfBuzz for normal builds.
- Core-only `zig build` and `zig build test` must not require `slangc`,
  Vulkan, Metal, Wayland, Cocoa, or a window toolkit.
- `slangc` is required for shader steps, backend builds, backend tests, and
  demos. It must support Slang 2026, SPIR-V 1.6, and `metallib_4_0`.
- Vulkan and Vulkan Headers dependencies must remain lazy.
- Linux Vulkan demo builds need `wayland-scanner`, `wayland-client`,
  `xkbcommon`, and the lazy `wayland_protocols_src` dependency.
- Metal builds are macOS-only and require Swift `6.3` or newer, a macOS 26.0
  or newer target, and an Apple SDK exposing Metal 4.
- Swift bridge sources must use the shared `build/swift.zig` policy:
  `xcrun --sdk macosx`, `-swift-version 6`, explicit SDK, explicit Apple target
  triple, Zig-cache module cache, and optimize-mode-specific flags.

## Core And Algorithm Rules

- Keep public value types in `src/core/types.zig` and renderer options under
  `src/core/render/options.zig`.
- `RendererCore` is the shared spine for font loading, shaping, glyph encoding,
  cache metadata, frame batches, meshlet planning, and deferred retirement.
- Coverage blobs are explicit 32-bit word streams. Keep separate protocol magic
  and `major.minor` version words for project-owned wire formats.
- Preserve CPU f64 `Transform`/`View` math for high-zoom stability.
- Preserve precision-tier validation and early rejection of unsupported
  transforms or renderer options.
- Use repository assets for tests. Do not rely on system font paths.

## GPU And Shader Rules

- The hot path uses:
  - one glyph blob storage buffer,
  - per-frame glyph instance buffers,
  - per-frame meshlet buffers,
  - optional shader-stats buffers.
- Vulkan frame bindings use Vulkan 1.4 push descriptors and linked
  `VK_EXT_shader_object` mesh/fragment shader objects. Do not reintroduce
  monolithic graphics pipelines, frame-local descriptor pools, descriptor-set
  allocation, or per-glyph descriptor slots.
- Metal command submission and resource binding should use the Metal 4 API
  family exposed by the Swift bridge. Avoid older command-queue,
  command-buffer, or stage-specific setter paths unless an architecture
  decision changes the backend.
- Slang entries should declare stages in source with `[shader(...)]`.
  `build/shaders.zig` owns target profiles, capabilities, warning policy,
  import paths, and reflected struct names.
- If shader ABI fields change, regenerate through the build graph and run the
  relevant backend plus `-Dshader-stats=true` variants.

## Platform Demo Rules

- Windows demo: keep a direct native Win32 host with `std.os.windows` types,
  documented `extern "user32"` window-management calls, ntdll only for
  `RtlQueryPerformanceCounter`/`Frequency` and `LdrLoadDll`, dynamic Vulkan/DWM
  loading, per-monitor DPI, native system commands, and the manifest in
  `demo/platform/windows.manifest`.
- Wayland demo: keep xdg-shell client-side decorations, logical sizing,
  fractional-scale buffer sizing, viewporter destination sizing,
  cursor-shape-v1, xkbcommon keymaps, xdg move/resize delegation, and
  linux-dmabuf feedback handling when advertised.
- Cocoa/Metal demo: keep SwiftUI/AppKit hosting, normal Cocoa menu/close/quit
  behavior, native window chrome, and a `CAMetalLayer`.
- All demos use `B` to switch explicit light/dark appearance. Do not make demos
  follow system appearance by default unless product policy changes.

## Build And CI Rules

- `build.zig` is the orchestration layer. Keep backend, demo, dependency,
  shader, Swift, and bundled C-library logic in `build/`.
- Keep lazy dependency resolution centralized in `build/deps.zig`.
- Keep shader artifacts cached in the configure graph instead of rebuilding
  separately for each consumer.
- Keep Swift toolchain resolution single-pass per Metal build graph.
- CI should remain a small public orchestrator plus reusable workflows and
  local composite actions.
- Windows CI may keep a tiny long-path setup script. Cross-platform Zig
  dependency prefetch belongs in shared Bash and PowerShell scripts.
- Bash scripts should pass `bash -n` and ShellCheck. PowerShell scripts should
  parse under PowerShell 7 with strict mode.

## Style

- Run `zig fmt build.zig build/ demo/ src/ tools/` before submitting Zig
  changes.
- Use lowercase module filenames, `PascalCase` public types, and `camelCase`
  functions and fields.
- Prefer renderer-domain names already used by the project:
  `GlyphInstance`, `GlyphMeshlet`, `FrameBatch`, `GlyphBlobRef`,
  `FrameBindings`, `BufferView`, `Transform`, `View`, `spirv`, `msl`,
  `mesh`, and `fragment`.
- Keep comments focused on invariants and non-obvious reasoning. Do not comment
  mechanics that are already clear from the code.
- Use `rg` and `rg --files` for search. Preserve unrelated user changes in a
  dirty worktree.

## Documentation Rules

- `README.md` is for humans evaluating or using the project. It should focus on
  purpose, architecture, technical highlights, public API, quick start,
  requirements, diagnostics, demos, credit, and license.
- `CHANGELOG.md` is for users upgrading. Group changes by release and change
  type; consolidate repeated implementation notes into user-visible bullets.
- `AGENTS.md` is for AI and maintainer execution. Put detailed commands,
  boundaries, verification expectations, and repository-specific rules here.
- Update `README.md` for changes to public modules, build commands, platform
  dependencies, backend requirements, shader layout, diagnostics, algorithmic
  invariants, Slug credit, or project positioning.
- Update `CHANGELOG.md` for notable user-visible API, build, dependency,
  backend, demo, CI, shader, or architecture changes.

## Testing Expectations

Use Zig `test` blocks and `std.testing`. Put tests near the implementation and
ensure nested modules are imported from a test-discovered root.

Preferred test names describe behavior:

```zig
test "RendererCore: skips empty glyph instances" {
    // ...
}
```

Coverage expectations:

- Core math/blob/cache changes: `zig build test`.
- Shader ABI changes: `zig build spirv`, `zig build msl`, and matching backend
  shader-stat tests.
- Vulkan backend changes: `zig build test -Dvulkan=true` and the Vulkan
  shader-stat variant.
- Metal backend changes: `zig build swift-format-lint`,
  `zig build test -Dmetal=true`, and the Metal shader-stat variant.
- Demo platform changes: matching `zig build test -Ddemo=true
  -Ddemo-backend=...` command.
- Build-system changes: core tests plus every affected optional backend/demo
  configuration.

## Commit Rules

- Use Conventional Commit subjects such as `feat:`, `fix:`, `refactor:`,
  `build:`, `ci:`, and `docs:`.
- Keep subjects imperative and scoped.
- Use signed and signed-off commits:

```bash
git commit -s -S
```

Before committing, check:

- Worktree diff contains only intentional changes.
- Required docs are updated.
- Required verification commands have run or any skipped commands are clearly
  explained.
- No generated artifacts are staged.
