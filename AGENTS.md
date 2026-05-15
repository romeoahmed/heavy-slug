# Repository Guidelines

## Project Structure & Module Organization

`heavy-slug` is a Zig 0.16 GPU text rendering library. The core module is `src/root.zig`; it exports font shaping, HarfBuzz GPU glyph encoding, PGA math, cache/pool utilities, and backend-neutral render orchestration from `src/render.zig`. The core does not own a GPU context or depend on GLFW.

Backend modules are opt-in. `src/vulkan/` provides `heavy_slug_vulkan` for Vulkan SPIR-V 1.6 mesh shaders. `src/metal/` provides `heavy_slug_metal` for macOS Metal 4 and accepts externally provided Metal device, command queue, and layer objects. Demo-only code lives in `src/demo/`; GLFW and Cocoa window setup must stay there. Shaders are in `shaders/`, and `tools/layout_gen.zig` generates GPU ABI structs from Slang reflection. Test assets live in `assets/`.

## Build, Test, and Development Commands

- `zig build` configures the core library.
- `zig build test` runs core and build-tool tests.
- `zig build test -Dvulkan=true` also builds and tests the Vulkan backend.
- `zig build test -Dmetal=true` also builds and tests the Metal backend on macOS.
- `zig build shaders` compiles Slang to SPIR-V 1.6.
- `zig build metal-shaders` compiles Slang to Metal 4 MSL.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16` runs the Windows/Linux Vulkan demo.
- `zig build run -Ddemo=true -Ddemo-backend=metal4` runs the macOS Metal demo.
- `zig build -Doptimize=ReleaseFast [-Dthinlto=auto|on|off]` builds release mode; `auto` enables ThinLTO only where Zig 0.16 can link it.

## Coding Style & Naming Conventions

Run `zig fmt build.zig src/ tools/` before submitting. Use lowercase module filenames, `PascalCase` public types, `camelCase` functions and fields, and descriptive constants matching local style. Keep shader layouts generated from reflection; do not hand-edit generated GPU structs. Use `build.zig` `addTranslateC()` modules for C headers instead of source-level `@cImport`.

## Testing Guidelines

Tests use Zig `test` blocks and `std.testing`. Put module tests near the implementation and import new modules from `src/root.zig` so nested tests are discovered. Prefer behavior names such as `test "TextCore: skips empty glyph commands"`. Use repository assets, not system font paths.

## Commit & Pull Request Guidelines

History uses Conventional Commit prefixes such as `feat:`, `refactor:`, `build:`, `ci:`, and `docs:`. Keep subjects imperative and scoped. Use signed-off, signed commits: `git commit -s -S`. Pull requests should describe API or behavior changes, list verification commands, link issues, and include screenshots or notes for rendering changes.

## Dependency & Configuration Notes

Dependencies are pinned in `build.zig.zon`; update with `zig fetch --save <url>`. Keep `vulkan`, `vulkan_headers`, and `glfw_src` lazy. Do not commit generated `zig-out/`, `.zig-cache/`, or `zig-pkg/` artifacts.
