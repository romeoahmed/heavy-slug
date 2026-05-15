# Repository Guidelines

## Project Structure & Module Organization

`heavy-slug` is a Zig GPU text rendering library. The public module is `src/root.zig`, with the demo entry point in `src/main.zig`. Core code is grouped by domain: `src/font/` wraps FreeType and HarfBuzz, `src/gpu/` contains Vulkan context, descriptors, pipeline, cache, pool, and renderer code, and `src/math/` contains PGA motor math. Demo-specific Vulkan and GLFW helpers live in `src/demo/`. Slang shaders are in `shaders/`; `tools/layout_gen.zig` generates Zig GPU structs from Slang reflection. Test assets currently live in `assets/`, especially `assets/Inter-Regular.otf`.

## Build, Test, and Development Commands

- `zig build` builds the library, compiles shaders, generates Vulkan bindings, and builds C dependencies.
- `zig build -Doptimize=ReleaseFast` builds an optimized release library with ThinLTO on C static libraries.
- `zig build shaders` compiles Slang shaders to SPIR-V only.
- `zig build test` runs library and `tools/layout_gen.zig` tests.
- `zig build -Ddemo=true` builds the interactive demo and fetches GLFW.
- `zig build run -Ddemo=true` runs the demo; requires Vulkan 1.4 with mesh shader support and `slangc` on `PATH`.

## Coding Style & Naming Conventions

Run `zig fmt src/ tools/` before submitting changes. Use idiomatic Zig naming: files and modules are lowercase, public types use `PascalCase`, functions and fields use `camelCase`, and constants use descriptive lower_snake or existing local style. Keep shader struct layouts driven by Slang reflection; do not hand-edit generated GPU structs. Prefer small domain modules over broad utility files.

## Testing Guidelines

Tests use Zig’s built-in `test` blocks and `std.testing`. Name tests by behavior, for example `test "GlyphCache: evict LRU cold entry"` or `test "integration: shape text and encode all unique glyphs"`. Add new module tests near the code they cover. Ensure `src/root.zig` imports new modules in its top-level `test` block so nested tests are discovered. Use repository assets instead of system font paths.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style prefixes such as `build:`, `docs:`, `ci:`, and `chore:`. Keep subjects imperative and scoped. Project notes require signed commits with `git commit -s -S`; follow that unless maintainers say otherwise. Pull requests should describe the behavior changed, list commands run, link related issues, and include demo screenshots or notes when visual rendering changes.

## Security & Configuration Tips

Dependencies are pinned in `build.zig.zon`; update them with `zig fetch --save <url>`. Keep `glfw_src` lazy so normal library builds avoid demo-only downloads. Do not commit generated `zig-out/` artifacts.
