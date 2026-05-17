# Repository Guidelines

## Project Identity

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic,
resolution-independent text. It shapes Unicode with HarfBuzz, captures native
font outlines, regularizes them into cubic coverage blobs, and renders those
blobs with task, mesh, and fragment shaders on Vulkan 1.4 and Metal 4.

Treat `README.md` as the canonical public architecture document. Update it when
you change public APIs, build commands, platform requirements, backend
contracts, shader layout, diagnostics, algorithmic invariants, Slug credit, or
project positioning. Update `CHANGELOG.md` for user-visible API, dependency,
build, backend, or architecture changes.

The library boundary is deliberate: core code must never own a GPU context,
swapchain, window, command queue, command buffer, CAMetalLayer lifecycle, or
window-toolkit object.

## Project Structure

- `src/root.zig` exports the public `heavy_slug` core API.
- `src/core/` owns public value types plus font, outline, blob, cache, and
  renderer-core internals.
- `src/gpu/` contains backend-neutral GPU ABI markers, mesh limits, resource
  model notes, and shader stats types.
- `src/math/` contains PGA motor math used by transforms.
- `src/backends/vulkan/` provides the opt-in `heavy_slug_vulkan` module.
- `src/backends/metal/` provides the opt-in `heavy_slug_metal` module and
  Objective-C++ bridge.
- `src/demo/common/` contains demo-only scene and input helpers.
- `src/demo/vulkan/` and `src/demo/metal/` contain platform demo hosts.
- `src/demo/platform/` contains native Win32, Wayland, and Cocoa window hosts.
- `src/c/` contains headers translated by build-system `addTranslateC()`.
- `build/` contains modular Zig build helpers.
- `shaders/core/` contains shared Slang 2026 ABI, stats, PGA, h-band, and
  coverage logic.
- `shaders/backend_vulkan/` and `shaders/backend_metal/` contain binding shims.
- `shaders/entries/` contains `task.slang`, `mesh.slang`, and
  `fragment.slang`.
- `tools/layout_gen.zig` generates Zig GPU ABI structs from Slang reflection.

## Build, Test, And Development Commands

- `zig build` builds the core library only.
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

Prefer the narrowest verification that covers your change, then broaden when
you touch shared contracts. Shader ABI, backend resource binding, and public API
changes require backend and shader-stat variants where the target supports them.

## Platform Dependencies

All platforms require Zig `0.16.0`. FreeType and HarfBuzz are pinned source
dependencies in `build.zig.zon` and are built statically by the Zig build; do
not require contributors to install system FreeType or HarfBuzz for normal
builds.

The bundled FreeType build is outline-focused for analytic text rendering. Keep
the generated `ftmodule`/`ftoption` config in `build/c_libs.zig` aligned with
the compiled source list. Do not reintroduce bitmap, compression, PNG, Brotli,
SVG, or FreeType auto-HarfBuzz helper dependencies without updating
`README.md` and `CHANGELOG.md`.

`slangc` must be on `PATH` for shader steps, backend builds, backend tests, and
demos. It must support Slang 2026, SPIR-V 1.6, and `metallib_4_0`. Core-only
`zig build` and `zig build test` must not require `slangc`.

Vulkan builds use lazy `vulkan` and `vulkan_headers` package dependencies.
Runtime/demo execution needs a Vulkan loader, a Vulkan 1.4 driver, core
`pushDescriptor`, `VK_EXT_mesh_shader`, task/mesh shader features, and
sufficient mesh limits. The Vulkan demo is supported on Windows and Linux.

Linux Vulkan demo builds also need `wayland-scanner`, `wayland-client` and
`xkbcommon` headers/libraries, and `wayland-protocols` with stable xdg-shell,
stable viewporter, and staging fractional-scale-v1 XML. Use
`-Dwayland-scanner=` or `-Dwayland-protocols-dir=` when those tools are outside
default Linux paths.
The Wayland host intentionally keeps only the CSD path: draw the client-side
frame with core `wl_subsurface`/`wl_shm`, delegate drag/resize to xdg-shell
`move`/`resize`, keep shm decoration buffers alive until `wl_buffer.release`,
and keep their count bounded under resize pressure. Use `xkbcommon` keymaps
from `wl_keyboard.keymap` rather than hard-coding layout-dependent keyboard
semantics.
For HiDPI, keep xdg-shell configure sizes and decoration geometry in
surface-local logical coordinates. Require `fractional-scale-v1`, render
Vulkan and CSD buffers at the compositor-preferred physical pixel extent, and
map them back with `wp_viewport.set_destination`.

Windows Vulkan demo builds use a direct Win32 host through Zig externs and
`std.os.windows` types, link `user32`, and dynamically load `vulkan-1.dll` at
runtime. Keep DWM title-bar dark-mode support optional by dynamically loading
`dwmapi.dll`; the scene's light/dark toggle should drive
`DWMWA_USE_IMMERSIVE_DARK_MODE`. Handle `WM_DPICHANGED` with the suggested
rectangle from Windows rather than manually guessing per-monitor scaling. For
initial sizing, use the window's `GetDpiForWindow()` DPI after default
placement, not `GetDpiForSystem()`, so multi-monitor DPI setups keep a
consistent logical client size. Do not switch the demo host to WinRT/Windows
App SDK just to appear newer; the current best fit for this low-level Vulkan
surface demo is direct Win32 `HWND` ownership with narrow DWM integration.

Metal builds are macOS-only and need an Apple SDK exposing Metal 4 APIs,
Objective-C++ compilation support, and the `Metal`, `QuartzCore`, and
`Foundation` frameworks. The Metal demo uses a direct Cocoa `NSWindow` and
`CAMetalLayer` host, installs normal Cocoa app menu actions, keeps the window
chrome native, handles Command+W/Command+Q through the same graceful-close path,
and links `Cocoa`, `QuartzCore`, `Metal`, and `Foundation`.

Keep `vulkan` and `vulkan_headers` lazy. Do not introduce backend, demo, or
window-system dependencies into core-only builds. Do not add GLFW, SDL, or a
similar window toolkit unless a documented architecture decision reverses the
native-demo-host model.

## Coding Style And Naming

Run `zig fmt build.zig build/ src/ tools/` before submitting code changes. Use
lowercase module filenames, `PascalCase` public types, `camelCase` functions
and fields, and descriptive constants matching local style.

Prefer semantic names tied to renderer roles:

- build steps: `spirv`, `msl`,
- demo backends: `vulkan`, `metal`,
- shader entries: `task`, `mesh`, `fragment`,
- shader language mode: explicit `#language slang 2026` modules,
- per-frame glyph records: `GlyphInstance`,
- per-frame glyph storage: `GlyphBatch`,
- glyph-pool references: `GlyphBlobRef`,
- shader ABI fields: `blob_ref`,
- Vulkan per-frame resource binding helper: `FrameBindings`,
- Vulkan pushed buffer range values: `BufferView`,
- Metal borrowed host object contract: `Host`.

Use build-system `addTranslateC()` modules for C headers instead of source-level
`@cImport`. Keep GPU layouts generated from Slang reflection; do not hand-edit
generated GPU structs. Slang entry stages should be declared in source with
`[shader(...)]`; keep `build/shaders.zig` as target/capability policy rather
than duplicating entry-stage names there.

## GPU Resource Rules

Preserve the single glyph-pool buffer model unless profiling proves a stronger
alternative. Do not reintroduce per-glyph Vulkan descriptor slots, Vulkan
descriptor indexing as the glyph addressing model, or `VK_EXT_descriptor_heap`
as architectural churn.

The hot path deliberately uses byte-offset `GlyphBlobRef` values. Vulkan frame
bindings use Vulkan 1.4 push descriptors, not frame-local descriptor pools,
descriptor-set allocation, or `vkUpdateDescriptorSets`.

Keep Vulkan pNext chains in `src/backends/vulkan/chains.zig`; use those chain
structs in demos and backend init paths rather than open-coded feature/property
chains. The Vulkan shader target is SPIR-V 1.6 via Slang `spirv_1_6` plus
explicit mesh/subgroup capability atoms. Do not describe Khronos SPIR-V 1.6
spec revisions as separately targetable build settings.

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

For numerical coverage work, include tests that exercise the reference path,
h-band candidate path, degenerate outlines, quantization boundaries, and
high-zoom transforms where practical.

## Documentation Guidelines

Document boundaries and invariants, not just filenames. Future readers need to
know why core stays GPU-free, why glyph blobs are addressed by byte offsets,
why reflection owns the GPU ABI, and why the shader path has a conservative
full-scan fallback.

Update `README.md` when changing:

- build commands,
- platform dependencies,
- public modules,
- backend requirements,
- shader layout,
- diagnostics,
- algorithmic invariants,
- Slug credit or project positioning.

Update `CHANGELOG.md` for notable user-visible, API, build, dependency, or
architecture changes. Keep entries under `[Unreleased]` until a release section
is cut.

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
