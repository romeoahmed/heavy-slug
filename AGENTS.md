# Repository Guidelines

## Project Identity

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines with FreeType, encodes precision-tiered cubic coverage blobs, and
renders them with mesh and fragment shaders on Vulkan 1.4 and Metal 4.

`README.md` is the canonical public architecture and build document. Keep it
accurate when changing public APIs, backend requirements, shader layout,
diagnostics, platform dependencies, algorithmic invariants, Slug credit, or
project positioning. Use `CHANGELOG.md` for notable user-visible API, build,
dependency, backend, demo, and architecture changes.

The core library boundary is deliberate: core code must not own a GPU context,
swapchain, surface, command queue, command buffer, window, `CAMetalLayer`, or
window-toolkit object.

## Project Structure

- `src/root.zig` exports the public `heavy_slug` core API.
- `src/core/` owns public value types plus font, outline, blob, cache, and
  renderer-core internals.
- `src/gpu/` contains backend-neutral GPU ABI markers, mesh limits, resource
  model notes, and shader stats types.
- `src/backends/vulkan/` provides the opt-in `heavy_slug_vulkan` module.
- `src/backends/metal/` provides the opt-in `heavy_slug_metal` module and the
  Objective-C++ bridge.
- `demo/common/` contains demo-only scene and input helpers.
- `demo/vulkan/` and `demo/metal/` contain demo entry points.
- `demo/platform/` contains native Win32, Wayland, and Cocoa hosts.
- `src/c/` contains core C headers translated by build-system `addTranslateC()`.
- `build/` contains modular Zig build helpers.
- `shaders/core/` contains shared Slang 2026 ABI, stats, chart mapping,
  h-band, and coverage logic.
- `shaders/backend_vulkan/` and `shaders/backend_metal/` contain binding shims.
- `shaders/entries/` contains `mesh.slang` and `fragment.slang`.
- `tools/layout_gen.zig` generates Zig GPU ABI structs from Slang reflection.

## Build, Test, And Development Commands

- `zig build` builds the core library only.
- `zig build test` runs core and build-tool tests.
- `zig build test -Dvulkan=true` builds and tests the Vulkan backend.
- `zig build test -Dmetal=true` builds and tests the Metal backend on macOS.
- `zig build test -Dvulkan=true -Dshader-stats=true` tests Vulkan shader
  counter bindings.
- `zig build test -Dmetal=true -Dshader-stats=true` tests Metal shader counter
  bindings.
- `zig build test -Dvulkan=true -Dmetal=true -Dshader-stats=true` tests both
  backend modules and shader counters where the target supports them.
- `zig build test -Ddemo=true -Ddemo-backend=vulkan` builds and tests the
  Windows/Linux Vulkan demo host path.
- `zig build test -Ddemo=true -Ddemo-backend=metal` builds and tests the macOS
  Metal demo host path.
- `zig build spirv` compiles Slang to SPIR-V 1.6.
- `zig build msl` compiles Slang to Metal Shading Language.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan` runs the Windows/Linux
  Vulkan demo.
- `zig build run -Ddemo=true -Ddemo-backend=metal` runs the macOS Metal demo.
- `zig build -Doptimize=ReleaseFast [-Dthinlto=auto|on|off]` builds release
  mode; `auto` enables ThinLTO only where Zig 0.16 can link it.

Run the narrowest verification that covers the change, then broaden when you
touch shared contracts. Public API, shader ABI, backend resource binding, and
demo platform changes usually require the matching backend and shader-stat
variants where supported.

## Platform Dependencies

All platforms require Zig `0.16.0`. FreeType and HarfBuzz are pinned source
dependencies in `build.zig.zon` and are built statically by the Zig build. Do
not require contributors to install system FreeType or HarfBuzz for normal
builds.

Core-only `zig build` and `zig build test` must not require `slangc`, Vulkan,
Metal, Wayland, Cocoa, or any window toolkit. Keep `vulkan` and
`vulkan_headers` lazy.

`slangc` must be on `PATH` for shader steps, backend builds, backend tests, and
demos. It must support Slang 2026, SPIR-V 1.6, and `metallib_4_0`.

Vulkan runtime/demo execution needs a Vulkan loader, a Vulkan 1.4 driver, core
push descriptors, `VK_EXT_mesh_shader`, `VK_EXT_shader_object`, mesh shader
features, dynamic rendering, and sufficient mesh limits. Keep Vulkan pNext
chains in `src/backends/vulkan/chains.zig`.

Linux Vulkan demo builds also need `wayland-scanner`, `wayland-client`,
`xkbcommon`, and the lazy `wayland_protocols_src` dependency pinned in
`build.zig.zon` for xdg-shell, viewporter, fractional-scale-v1,
cursor-shape-v1, and stable tablet-v2 XML. The demo host uses the modern
Wayland path with
client-side decorations; preserve logical surface sizing, fractional-scale
buffer sizing, xkbcommon keymaps, and xdg-shell move/resize delegation.

Windows Vulkan demo builds use a direct Win32 host through Zig externs and
`std.os.windows` types. Keep Vulkan loader and optional DWM integration
dynamically loaded. Preserve per-monitor DPI handling and native system command
behavior. Do not switch the low-level Vulkan surface demo to WinRT or Windows
App SDK without a documented architecture decision.

Metal builds are macOS-only and need an Apple SDK exposing Metal 4 APIs,
Objective-C++ C++23 compilation support, and the `Metal`, `QuartzCore`, and
`Foundation` frameworks. The Metal demo uses a direct Cocoa host, normal Cocoa
menu/close/quit handling, native window chrome, and a `CAMetalLayer`.
Keep Objective-C++ sources on the shared `build/objcxx.zig` compiler policy:
ARC on, exceptions and RTTI off, warnings as errors, and optimize-mode-specific
`-O0`/`-O3`/`-Os` flags.

Do not add GLFW, SDL, or a similar window toolkit unless a documented
architecture decision reverses the native-demo-host model.

## Coding Style And Naming

Run `zig fmt build.zig build/ demo/ src/ tools/` before submitting code
changes. Use lowercase module filenames, `PascalCase` public types,
`camelCase` functions and fields, and descriptive constants matching local
style.

Prefer semantic names tied to renderer roles:

- build steps: `spirv`, `msl`,
- demo backends: `vulkan`, `metal`,
- shader entries: `mesh`, `fragment`,
- shader language mode: explicit `#language slang 2026` modules,
- per-frame glyph records: `GlyphInstance`,
- per-frame glyph and meshlet storage: `FrameBatch`,
- glyph-pool references: `GlyphBlobRef`,
- shader ABI fields: `blob_ref`,
- Vulkan per-frame resource binding helper: `FrameBindings`,
- Vulkan pushed buffer range values: `BufferView`,
- Metal borrowed host object contract: `Host`.

Use build-system `addTranslateC()` modules for C headers instead of source-level
`@cImport`. Keep GPU layouts generated from Slang reflection; do not hand-edit
generated GPU structs. Slang entry stages should be declared in source with
`[shader(...)]`; keep `build/shaders.zig` as target/capability policy.

## GPU Resource Rules

Preserve the single glyph-pool buffer model unless profiling proves a stronger
alternative. Do not reintroduce per-glyph Vulkan descriptor slots, Vulkan
descriptor indexing as the glyph addressing model, or descriptor-heap style
architecture churn.

The hot path uses byte-offset `GlyphBlobRef` values. Vulkan frame bindings use
Vulkan 1.4 push descriptors and linked `VK_EXT_shader_object` shader objects,
not frame-local descriptor pools, descriptor set allocation, or monolithic
graphics pipelines.

For Metal, new command submission and resource binding work should use the
Metal 4 API family exposed by the bridge. Avoid older command-queue,
command-buffer, or stage-specific setter patterns unless an architecture
decision changes the backend model. Keep Zig-facing Metal bridge declarations
in `src/backends/metal/context.zig`; `renderer.zig` should stay focused on
renderer state, frame slots, and `RendererCore` coordination.

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
bindings or GPU ABI fields change. For numerical coverage work, include tests
for reference behavior, candidate paths, degenerate outlines, quantization
edges, and high-zoom transforms where practical.

## Documentation Guidelines

Document boundaries and invariants, not implementation trivia. Future readers
need to know why core stays GPU/window-system free, why glyph blobs are byte
offsets, why reflection owns the GPU ABI, and where correctness fallbacks
exist. Detailed platform API mechanics usually belong in code, tests, or
changelog entries, not in the public README.

Update `README.md` when changing:

- build commands,
- platform dependencies,
- public modules,
- backend requirements,
- shader layout,
- diagnostics,
- algorithmic invariants,
- Slug credit or project positioning.

Update `CHANGELOG.md` for notable user-visible, API, build, dependency,
backend, demo, or architecture changes. Keep entries under `[Unreleased]`
until a release section is cut.

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

Dependencies are pinned in `build.zig.zon`; update them with:

```bash
zig fetch --save <url>
```

Do not commit generated artifacts:

- `zig-out/`,
- `.zig-cache/`,
- `zig-pkg/`.
