# Repository Guidelines

## Project Structure & Module Organization

`heavy-slug` is a Zig 0.16 GPU text rendering library for analytic text. The core module is `src/root.zig`; it exports stable public types from `src/core/` and keeps font, outline, blob, cache, math, and render orchestration under explicit `heavy_slug.core.*` or private modules. The core does not own a GPU context or depend on GLFW.

Backend modules are opt-in. `src/backends/vulkan/` provides `heavy_slug_vulkan` for Vulkan 1.4 / SPIR-V 1.6 mesh shaders with `VK_EXT_mesh_shader`; glyph blobs are addressed as byte offsets into one storage buffer, not as per-glyph descriptors. `src/backends/metal/` provides `heavy_slug_metal` for macOS Metal 4 and accepts externally provided `id<MTLDevice>`, `id<MTL4CommandQueue>`, and `CAMetalLayer *`; the bridge uses the MTL4 command allocator, compiler/pipeline, and argument-table binding model. Demo-only code lives in `src/demo/`; shared scene/input code is in `src/demo/common/`, and platform hosts stay under `src/demo/vulkan/` and `src/demo/metal/`. Shared Slang modules are in `shaders/core/`, entry points are in `shaders/entries/`, and `tools/layout_gen.zig` generates GPU ABI structs from Slang reflection. `README.md` is the canonical high-level architecture and algorithm overview, including the Slug credit and the native cubic analytics plus task/mesh culling design.

## Build, Test, and Development Commands

- `zig build` configures the core library.
- `zig build test` runs core and build-tool tests.
- `zig build test -Dvulkan=true` also builds and tests the Vulkan backend.
- `zig build test -Dmetal=true` also builds and tests the Metal backend on macOS.
- `zig build test -Dvulkan=true -Dshader-stats=true` verifies the Vulkan backend with opt-in GPU shader counters.
- `zig build test -Dmetal=true -Dshader-stats=true` verifies the Metal backend with opt-in GPU shader counters.
- `zig build test -Dvulkan=true -Dmetal=true -Dshader-stats=true` verifies both backend modules and shader-counter bindings together.
- `zig build spirv` compiles Slang to SPIR-V 1.6.
- `zig build msl` compiles Slang to Metal 4 MSL.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan` runs the Windows/Linux Vulkan demo.
- `zig build run -Ddemo=true -Ddemo-backend=metal` runs the macOS Metal demo.
- `zig build -Doptimize=ReleaseFast [-Dthinlto=auto|on|off]` builds release mode; `auto` enables ThinLTO only where Zig 0.16 can link it.

## Coding Style & Naming Conventions

Run `zig fmt build.zig build/ src/ tools/` before submitting. Use lowercase module filenames, `PascalCase` public types, `camelCase` functions and fields, and descriptive constants matching local style. Keep shader layouts generated from reflection; do not hand-edit generated GPU structs. Use build-system `addTranslateC()` modules for C headers instead of source-level `@cImport`.

For GPU resources, preserve the single glyph-pool buffer model unless profiling proves a stronger alternative. Do not reintroduce per-glyph Vulkan descriptor slots, Vulkan descriptor indexing, or `VK_EXT_descriptor_heap` as architectural churn; the current hot path deliberately uses byte-offset `GlyphBlobRef` values. For Metal, new command submission and resource binding work should use the MTL4 API family rather than legacy `MTLCommandQueue`/`MTLCommandBuffer`/stage-specific buffer setters.

## Testing Guidelines

Tests use Zig `test` blocks and `std.testing`. Put module tests near the implementation and import new modules from `src/root.zig` so nested tests are discovered. Prefer behavior names such as `test "RendererCore: skips empty glyph instances"`. Use repository assets, not system font paths.

## Commit & Pull Request Guidelines

History uses Conventional Commit prefixes such as `feat:`, `refactor:`, `build:`, `ci:`, and `docs:`. Keep subjects imperative and scoped. Use signed-off, signed commits: `git commit -s -S`. Pull requests should describe API or behavior changes, list verification commands, link issues, and include screenshots or notes for rendering changes.

## Dependency & Configuration Notes

Dependencies are pinned in `build.zig.zon`; update with `zig fetch --save <url>`. Keep `vulkan`, `vulkan_headers`, and `glfw_src` lazy. Do not commit generated `zig-out/`, `.zig-cache/`, or `zig-pkg/` artifacts.
