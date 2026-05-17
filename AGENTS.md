# Repository Guidelines

## Project Identity

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. The renderer shapes text with HarfBuzz, captures
native outlines, encodes cubic coverage blobs, and renders those blobs with
task, mesh, and fragment shaders on Vulkan 1.4 and Metal 4.

`README.md` is the canonical high-level architecture, algorithm, dependency,
and Slug-credit document. Keep it accurate when changing public APIs, backend
requirements, shader layout, build commands, or major algorithmic behavior.

## Project Structure

- `src/root.zig` exports the public `heavy_slug` core API.
- `src/core/` contains public value types plus font, outline, blob, cache, and
  renderer-core internals.
- `src/gpu/` contains backend-neutral GPU ABI markers, mesh limits, resource
  model notes, and shader stats types.
- `src/math/` contains PGA motor math used by transforms.
- `src/backends/vulkan/` provides the opt-in `heavy_slug_vulkan` module.
- `src/backends/metal/` provides the opt-in `heavy_slug_metal` module and
  Objective-C++ bridge.
- `src/demo/common/` contains demo-only scene/input helpers.
- `src/demo/vulkan/` and `src/demo/metal/` contain platform demo hosts.
- `src/c/` contains headers translated by build-system `addTranslateC()`.
- `build/` contains modular Zig build helpers.
- `shaders/core/` contains shared Slang logic.
- `shaders/backend_vulkan/` and `shaders/backend_metal/` contain binding shims.
- `shaders/entries/` contains `task.slang`, `mesh.slang`, and
  `fragment.slang`.
- `tools/layout_gen.zig` generates GPU ABI structs from Slang reflection.

The core library must not own a GPU context, swapchain, window, command queue,
or GLFW object.

## Build, Test, And Development Commands

- `zig build` builds the core library.
- `zig build test` runs core and build-tool tests.
- `zig build test -Dvulkan=true` builds and tests the Vulkan backend.
- `zig build test -Dmetal=true` builds and tests the Metal backend on macOS.
- `zig build test -Dvulkan=true -Dshader-stats=true` tests Vulkan with shader
  counter bindings.
- `zig build test -Dmetal=true -Dshader-stats=true` tests Metal with shader
  counter bindings.
- `zig build test -Dvulkan=true -Dmetal=true -Dshader-stats=true` tests both
  backend modules and shader-counter bindings where the target supports them.
- `zig build spirv` compiles Slang to SPIR-V 1.6.
- `zig build msl` compiles Slang to Metal Shading Language.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan` runs the Windows/Linux
  Vulkan demo.
- `zig build run -Ddemo=true -Ddemo-backend=metal` runs the macOS Metal demo.
- `zig build -Doptimize=ReleaseFast [-Dthinlto=auto|on|off]` builds release
  mode; `auto` enables ThinLTO only where Zig 0.16 can link it.

## Platform Dependencies

All platforms require Zig `0.16.0`. FreeType and HarfBuzz are pinned source
dependencies in `build.zig.zon` and are built statically by the Zig build; do
not require contributors to install system FreeType or HarfBuzz for normal
builds.

The bundled FreeType build is outline-focused for analytic text rendering. Keep
its generated `ftmodule`/`ftoption` config in `build/c_libs.zig` aligned with
the compiled source list, and do not reintroduce bitmap/compression/SVG helper
dependencies without updating `README.md` and `CHANGELOG.md`.

`slangc` must be on `PATH` for shader steps, backend builds, backend tests, and
demos. Core-only `zig build` and `zig build test` do not require `slangc`.

Vulkan builds use lazy `vulkan` and `vulkan_headers` package dependencies.
Runtime/demo execution needs a Vulkan loader, a Vulkan 1.4 driver, and
core `pushDescriptor` plus `VK_EXT_mesh_shader` with task/mesh shader features
and sufficient mesh limits. The Vulkan demo is supported on Windows and Linux.

Linux Vulkan demo builds also need `wayland-scanner` plus development libraries
for `wayland-client`, `wayland-cursor`, `wayland-egl`, and `xkbcommon`.

Windows Vulkan demo builds use GLFW's Win32 backend and link `gdi32`, `user32`,
and `shell32`.

Metal builds are macOS-only and need an Apple SDK exposing Metal 4 APIs,
Objective-C++ compilation support, and the `Metal`, `QuartzCore`, and
`Foundation` frameworks. The Metal demo also uses GLFW's Cocoa backend and
links `Cocoa`, `IOKit`, and `CoreFoundation`.

Keep `vulkan`, `vulkan_headers`, and `glfw_src` lazy. Do not introduce backend
or demo dependencies into core-only builds.

## Coding Style And Naming

Run `zig fmt build.zig build/ src/ tools/` before submitting code changes. Use
lowercase module filenames, `PascalCase` public types, `camelCase` functions
and fields, and descriptive constants matching local style.

Prefer semantic names tied to renderer roles:

- build steps: `spirv`, `msl`,
- demo backends: `vulkan`, `metal`,
- shader entries: `task`, `mesh`, `fragment`,
- per-frame glyph records: `GlyphInstance`,
- per-frame glyph storage: `GlyphBatch`,
- glyph-pool references: `GlyphBlobRef`,
- shader ABI fields: `blob_ref`.
- Vulkan per-frame resource binding helper: `FrameBindings`.
- Vulkan pushed buffer range values: `BufferView`.
- Metal borrowed host object contract: `Host`.

Use build-system `addTranslateC()` modules for C headers instead of source-level
`@cImport`. Keep GPU layouts generated from Slang reflection; do not hand-edit
generated GPU structs.

## GPU Resource Rules

Preserve the single glyph-pool buffer model unless profiling proves a stronger
alternative. Do not reintroduce per-glyph Vulkan descriptor slots, Vulkan
descriptor indexing as the glyph addressing model, or `VK_EXT_descriptor_heap`
as architectural churn. The current hot path deliberately uses byte-offset
`GlyphBlobRef` values and Vulkan 1.4 push descriptors for per-frame bindings.
Keep Vulkan pNext chains in `chains.zig`; use the chain structs there rather
than open-coded feature/property chains in demos or backend init paths.

For Metal, new command submission and resource binding work should use the
Metal 4 API family: `MTL4CommandQueue`, `MTL4CommandAllocator`,
`MTL4Compiler`, mesh render pipeline descriptors, and `MTL4ArgumentTable`.
Avoid legacy `MTLCommandQueue`, `MTLCommandBuffer`, or stage-specific buffer
setters unless a documented architecture decision changes the backend model.
Keep Zig-facing Metal bridge declarations in `src/backends/metal/context.zig`;
`renderer.zig` should stay focused on renderer state, frame slots, and
`RendererCore` coordination.

## Testing Guidelines

Tests use Zig `test` blocks and `std.testing`. Put module tests near the
implementation and import new modules from `src/root.zig` or an existing
test-discovered module so nested tests run.

Prefer behavior names such as:

```zig
test "RendererCore: skips empty glyph instances" {
    // ...
}
```

Use repository assets, not system font paths. When changing backend contracts,
run the matching backend test command and the relevant shader-stat variant when
bindings or GPU ABI fields change.

## Documentation Guidelines

Update `CHANGELOG.md` for notable user-visible, API, build, dependency, or
architecture changes. Keep entries under `[Unreleased]` until a release section
is cut.

Update `README.md` when changing:

- build commands,
- platform dependencies,
- public modules,
- backend requirements,
- shader layout,
- diagnostics,
- algorithmic invariants,
- Slug credit or project positioning.

Prefer documenting why a boundary exists, not only what file contains it.

## Commit And Pull Request Guidelines

History uses Conventional Commit prefixes such as `feat:`, `refactor:`,
`build:`, `ci:`, and `docs:`. Keep subjects imperative and scoped.

Use signed-off, signed commits:

```bash
git commit -s -S
```

Pull requests should describe API or behavior changes, list verification
commands, link issues, and include screenshots or notes for rendering changes.

## Dependency And Artifact Notes

Dependencies are pinned in `build.zig.zon`; update with:

```bash
zig fetch --save <url>
```

Do not commit generated artifacts:

- `zig-out/`,
- `.zig-cache/`,
- `zig-pkg/`.
