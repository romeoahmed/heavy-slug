# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-04-10

### Added

- **MIT license** and **README.md** with usage examples, architecture overview, and build instructions
- **GitHub Actions CI** (`.github/workflows/test.yaml`): lint, test, and release build jobs using Vulkan SDK and Zig
- **ThinLTO** on C static libraries (FreeType, HarfBuzz, GLFW) in release builds for cross-language optimization

### Changed

- **`-Ddemo` build flag** (default `false`): library consumers no longer fetch or compile GLFW -- pass `-Ddemo=true` to build the demo executable
- **`build.zig` reorganized** into clear sections: options, Vulkan bindings, shaders, GPU structs, library module, C deps, LTO, tests, demo

## [1.0.0] - 2026-04-09

### Added

- **Core library** (`src/root.zig`): GPU text rendering via the Slug algorithm (Eric Lengyel) for exact quadratic Bezier coverage
- **PGA motor math** (`src/math/pga.zig`): Cl(2,0,1) 2D motors with `@Vector(4,f32)` SIMD -- translation, rotation, composition, `composeTranslation` hot path, `unitize`, `toMat` projection embedding
- **FreeType integration** (`src/font/ft.zig`): Font loading via FreeType 2.14.3 compiled from source
- **HarfBuzz integration** (`src/font/hb.zig`): Unicode text shaping and HarfBuzz GPU glyph encoding via HarfBuzz 14.1.0
- **FontContext** (`src/font/glyph.zig`): Combined font pipeline -- shape text, encode glyphs to Slug format blobs
- **VulkanContext** (`src/gpu/context.zig`): Device wrapper with filtered dispatch, feature validation for `VK_EXT_mesh_shader` and `VK_EXT_robustness2`
- **Mesh shader pipeline** (`src/gpu/pipeline.zig`): Task + mesh + fragment pipeline with embedded SPIR-V, dynamic rendering (no VkRenderPass)
- **Bindless descriptors** (`src/gpu/descriptors.zig`): Descriptor table with slot allocator for glyph storage buffers
- **Glyph cache** (`src/gpu/cache.zig`): Two-tier hot/cold LRU cache with O(1) eviction via index-based doubly-linked list, automatic cold-to-hot promotion
- **Pool allocator** (`src/gpu/pool.zig`): Bump + free-list sub-allocator for GPU buffer memory, aligned to `minStorageBufferOffsetAlignment`
- **TextRenderer** (`src/gpu/renderer.zig`): Public API -- `init`, `loadFont`, `unloadFont`, `begin`/`drawText`/`flush` render loop
- **Slang shaders** (`shaders/`): Task shader (frustum cull), mesh shader (dilated quad), fragment shader (Slug band lookup + coverage), PGA motor math, shared types
- **GPU struct generation** (`tools/layout_gen.zig`): Build-time tool that parses `slangc -reflection-json` output and generates `extern struct` Zig types -- shader is single source of truth
- **Interactive demo** (`src/main.zig`): Pan, zoom, right-drag rotation with momentum, dark mode (B), reset (R), FPS counter, lorem ipsum text viewer
- **GLFW wrapper** (`src/demo/glfw.zig`): GLFW 3.4 with manual Vulkan externs to avoid vulkan.h conflicts
- **Demo Vulkan bootstrap** (`src/demo/vulkan.zig`): Instance, device, swapchain, double-buffered frame sync
- **Wayland support**: Linux builds use Wayland backend for GLFW
- **Integration tests**: 8 cross-module tests in `src/root.zig` covering font pipeline, cache+pool coordination, and motor+font positioning -- all without a live Vulkan device
- **Unit tests**: Comprehensive tests across all modules (context, descriptors, pipeline, pool, cache, renderer, PGA, font, glyph, layout_gen)

[Unreleased]: https://github.com/romeoahmed/heavy-slug/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/romeoahmed/heavy-slug/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/romeoahmed/heavy-slug/releases/tag/v1.0.0
