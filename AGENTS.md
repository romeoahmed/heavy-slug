# Repository Guidelines

## Project Structure & Module Organization

`heavy-slug` is a Zig text rendering library split into a core module and an opt-in Vulkan backend. The public core module is `src/root.zig`; it exports `font`, `pga`, `cache`, and `pool` without importing Vulkan. Vulkan SPIR-V 1.6 code lives in `src/vulkan/` and is exposed as `heavy_slug_vulkan` when built with `-Dvulkan=true` or the Windows/Linux demo backend. Demo entry points live in `src/main.zig` for Vulkan and `src/demo/metal4_main.zig` for the macOS Metal 4 path. Slang shaders are in `shaders/`; `tools/layout_gen.zig` generates Zig GPU structs from Slang reflection. Test assets live in `assets/`.

## Build, Test, and Development Commands

- `zig build` configures the core library and builds core C dependencies when a compile/test step needs them.
- `zig build -Doptimize=ReleaseFast` builds an optimized release library with ThinLTO on C static libraries.
- `zig build -Dvulkan=true` enables the Vulkan backend module and lazy-loads Vulkan packages.
- `zig build shaders` compiles Slang shaders to SPIR-V only.
- `zig build test` runs library and `tools/layout_gen.zig` tests.
- `zig build test -Dvulkan=true` also runs Vulkan backend tests.
- `zig build run -Ddemo=true -Ddemo-backend=vulkan_spirv16` runs the Windows/Linux Vulkan demo; requires Vulkan 1.4 mesh shaders and `slangc`.
- `zig build run -Ddemo=true -Ddemo-backend=metal4` selects the macOS Metal 4 demo entry point.

## Coding Style & Naming Conventions

Run `zig fmt src/ tools/` before submitting changes. Use idiomatic Zig naming: files and modules are lowercase, public types use `PascalCase`, functions and fields use `camelCase`, and constants use descriptive lower_snake or existing local style. Keep shader struct layouts driven by Slang reflection; do not hand-edit generated GPU structs. Keep backend-specific APIs under `src/vulkan/` or `src/demo/`, not the core root module.

## Testing Guidelines

Tests use Zig’s built-in `test` blocks and `std.testing`. Name tests by behavior, for example `test "GlyphCache: evict LRU cold entry"` or `test "integration: shape text and encode all unique glyphs"`. Add new module tests near the code they cover. Ensure `src/root.zig` imports new modules in its top-level `test` block so nested tests are discovered. Use repository assets instead of system font paths.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style prefixes such as `build:`, `docs:`, `ci:`, and `chore:`. Keep subjects imperative and scoped. Project notes require signed commits with `git commit -s -S`; follow that unless maintainers say otherwise. Pull requests should describe the behavior changed, list commands run, link related issues, and include demo screenshots or notes when visual rendering changes.

## Security & Configuration Tips

Dependencies are pinned in `build.zig.zon`; update them with `zig fetch --save <url>`. Keep `vulkan`, `vulkan_headers`, and `glfw_src` lazy so normal core builds avoid backend-only downloads. Do not commit generated `zig-out/` artifacts.
