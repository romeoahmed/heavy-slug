# heavy-slug

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![Vulkan](https://img.shields.io/badge/Vulkan-1.4-ac162c)](https://www.vulkan.org/)
[![Metal](https://img.shields.io/badge/Metal-4-8f8f8f)](https://developer.apple.com/metal/)
[![Slang](https://img.shields.io/badge/Slang-2026-2d6cdf)](https://shader-slang.org/)
[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE)

`heavy-slug` is a Zig 0.16 library for analytic, resolution-independent GPU
text rendering. It shapes Unicode with HarfBuzz, captures native font outlines
with FreeType and HarfBuzz draw callbacks, encodes compact cubic coverage blobs,
and renders text with mesh and fragment shaders on Vulkan 1.4 and Metal 4.

It follows the central idea of
[Slug](https://jcgt.org/published/0006/02/02/): keep glyph coverage analytic
until the fragment shader instead of baking text into a raster atlas. The public
boundary is deliberately small: applications own windows, devices, queues,
swapchains or layers, command buffers, frame completion, and presentation;
`heavy-slug` owns shaping, glyph encoding, cache state, and backend draw data.

```text
UTF-8 text -> HarfBuzz shaping -> cubic coverage blob
           -> CPU h-band meshlets -> analytic GPU coverage
```

## Contents

- [Use The Library](#use-the-library)
- [Architecture](#architecture)
- [Algorithm](#algorithm)
- [Requirements](#requirements)
- [Backends And Demos](#backends-and-demos)
- [Development](#development)
- [Credit](#credit)
- [License](#license)

## Use The Library

Enable the module you need, then let the host application keep ownership of the
graphics objects and call the backend renderer from its frame loop.

| Module | Enable With | Purpose |
| --- | --- | --- |
| `heavy_slug` | default | Backend-neutral value types and core renderer options. |
| `heavy_slug_vulkan` | `-Dvulkan=true` or Vulkan demo builds | Vulkan 1.4 backend. |
| `heavy_slug_metal` | `-Dmetal=true` or Metal demo builds | Metal 4 backend. |

Primary `heavy_slug` exports are `FontSource`, `FontOptions`, `FontHandle`,
`TextRun`, `Color`, `Transform`, `View`, `PrecisionPolicy`, `FillRule`,
`RendererOptions`, `FrameToken`, and `ShaderStats`. Backend modules expose the
application-facing flow through `Context`, `Renderer`, `Frame`, `Target`,
`RendererOptions`, `FontHandle`, `FrameToken`, `Stats`, and
`shader_stats_enabled`. Vulkan also exposes requirement helpers such as
`required_api_version` and `required_device_extensions`; Metal exposes `Host`,
the borrowed native object bundle used to create a backend context.

Typical frame shape:

```zig
const heavy_slug = @import("heavy_slug");

const font = try renderer.loadFont(.{ .path = "assets/Inter-Regular.otf" }, .{
    .size_px = 32,
});

const view = heavy_slug.View.identity(width_px, height_px);
var frame = try renderer.beginFrame(view);
try frame.drawText(.{
    .font = font,
    .text = "Heavy Slug",
    .transform = heavy_slug.Transform.translation(80, 140),
    .color = heavy_slug.Color.white,
});

const token = try frame.submit(target);
```

Useful commands:

| Goal | Command |
| --- | --- |
| Build the core library | `zig build` |
| Run core and build-tool tests | `zig build test` |
| Test Vulkan or Metal | `zig build test -Dvulkan=true` / `zig build test -Dmetal=true` |
| Compile shaders | `zig build spirv` / `zig build msl` |
| Run a demo | `zig build run -Ddemo=true -Ddemo-backend=vulkan` or `-Ddemo-backend=metal` |

`-Ddemo-backend=auto` chooses Vulkan on Windows/Linux and Metal on macOS.
`-Dshader-stats=true` adds GPU-side counters for shader diagnostics.

## Architecture

```text
Application
  owns window, graphics device, queues, swapchain/layer, frame completion
      |
      v
Backend: heavy_slug_vulkan or heavy_slug_metal
  owns GPU buffers, shader state, draw recording/submission glue
      |
      v
Core: heavy_slug
  owns fonts, shaping, outline normalization, blob encoding, cache metadata
      |
      v
Slang mesh and fragment shaders
  clip meshlets and integrate analytic coverage
```

The hot path uses one byte-addressed glyph blob pool plus compact per-frame
glyph and meshlet streams. Cached glyphs are keyed by font, glyph id, precision
tier, and variation key; cache entries retire only after the frame token that
may reference them has completed.

## Algorithm

`heavy-slug` is useful when text is transformed, zoomed, panned, or reused
without wanting a new raster atlas for every scale. A glyph is cached as a
small analytic coverage program: fixed-point cubic Bezier spans plus a
conservative horizontal-band candidate index. The mesh shader bounds where work
can happen; the fragment shader computes the curve coverage for the current
pixel.

**Cubic Bernstein blobs**

All outline segments are raised to cubic Bernstein spans:

```math
\begin{aligned}
B(t) &= \sum_{i=0}^{3} p_i B_i^3(t),\\
B_i^3(t) &= \binom{3}{i}(1-t)^{3-i}t^i,\qquad 0 \le t \le 1 .
\end{aligned}
```

The CPU splits cubics at roots of $x'(t)$, $y'(t)$, and
$\det(B'(t),B''(t))$, then bisects any span whose quantized control polygon is
still not monotone on both axes. By the Bernstein convex-hull property, this
makes simple outward-rounded bounds useful for fast rejection.

Fill direction comes from the exact Green-form area integral, not a
control-polygon approximation. For one cubic span, with
$[a,b]=a_x b_y-a_y b_x$:

```math
\begin{aligned}
A_c=\frac{1}{20}(&6[p_0,p_1]+3[p_0,p_2]+[p_0,p_3]\\
&+3[p_1,p_2]+3[p_1,p_3]+6[p_2,p_3]).
\end{aligned}
```

**Coverage integral**

For a local pixel cell

```math
P=[-\tfrac12,\tfrac12]\times[-\tfrac12,\tfrac12],
```

Fubini turns coverage area into horizontal slice length, and Green turns each
oriented boundary contribution into a line integral. After clipping a
y-monotone span to the pixel y-range, the shader accumulates:

```math
I(\gamma)=
\int_a^b \mathrm{clamp}(x(t)+\tfrac12,\,0,\,1)\,y'(t)\,dt .
```

Spans wholly left of the cell contribute `0`; spans wholly right contribute
$y(b)-y(a)$; partial spans use the integral above. The signed sum resolves to
non-zero winding or even-odd fill.

**Stable quintic evaluation**

For a partial span,

```math
x(t)-x_L=\sum_{i=0}^{3}\xi_i B_i^3(t),\qquad
y'(t)=3\sum_{j=0}^{2}\Delta y_j B_j^2(t),
```

so the integrand is a degree-five Bernstein polynomial:

```math
(x(t)-x_L)y'(t)=\sum_{k=0}^{5} q_k B_k^5(t),
\qquad
q_k=3\sum_{i+j=k}\xi_i\Delta y_j\,
\frac{\binom{3}{i}\binom{2}{j}}{\binom{5}{k}} .
```

The sum for $q_k$ ranges over valid pairs $0\le i\le3$, $0\le j\le2$ with
$i+j=k$. Three-point Gauss-Legendre integration is exact for degree-five
polynomials, and the shader evaluates the cubic and first-difference derivative
in factorized Bernstein/de Casteljau form rather than expanding to the power
basis. That keeps the stable cases explicit and avoids avoidable cancellation.

**Precision and acceleration**

The public `PrecisionPolicy` chooses even fixed-point tiers from a screen-space
error budget. If $A$ is the local-to-screen linear map and $n$ fraction bits are
used, the policy bounds rounding error by:

```math
\|A\|_\infty\,2^{-(n+1)} .
```

It requires that value to stay below `target_error_px`, rejects non-finite or
ill-conditioned transforms, and encodes glyph bounds with outward rounding.

The h-band table is a conservative CSR index from y bands to curve ids:

```math
\{i:\mathrm{bbox}_y(C_i)\cap H_k\ne\varnothing\}
  \subseteq \mathrm{candidates}(H_k).
```

Fragments merge a bounded number of adjacent band lists and deduplicate curve
ids before integration; if the window is invalid or too wide, the shader falls
back to a full curve scan.

## Requirements

Core builds need Zig `0.16.0`. FreeType `2.14.3` and HarfBuzz `14.2.0` are
pinned source dependencies; Zig compiles and links them statically, so normal
core builds do not require a separate C/C++ compiler or system FreeType/HarfBuzz
packages.

Backend and demo commands add native toolchains:

| Path | Additional Requirements |
| --- | --- |
| Shaders | `slangc` with Slang 2026, SPIR-V 1.6, and `metallib_4_0` support. |
| Vulkan | Vulkan loader, Vulkan 1.4 driver, push descriptors, dynamic rendering, `VK_EXT_mesh_shader`, and `VK_EXT_shader_object`. |
| Metal | macOS 26.0+, Swift 6.3, Apple SDK with Metal 4, and Metal/QuartzCore/Foundation/AppKit/SwiftUI. |
| Wayland demo | `wayland-scanner`, `wayland-client`, `xkbcommon`, and pinned Wayland protocol XML dependencies. |

Core-only `zig build` and `zig build test` do not require `slangc`, Vulkan,
Metal, Wayland, Cocoa, or a window toolkit.

## Backends And Demos

The demos are native host examples, not a portability layer. Vulkan uses Win32
or Wayland; Metal uses SwiftUI/AppKit with a `CAMetalLayer`. All demos use `B`
to switch between explicit light and dark appearance.

Vulkan hosts report completed GPU work with `Renderer.markFrameComplete(token)`.
The Metal backend tracks completion through bridge-managed frame slots and waits
for submitted work during teardown. `Renderer.stats()` exposes CPU/backend
counters for shaping, cache, uploads, retirements, pool state, submitted glyphs,
and meshlets; `-Dshader-stats=true` adds GPU counters for meshlet culling,
h-band candidate use, full-scan fallback, bbox rejection, and curve integration.

## Development

Run the narrowest verification that covers the change, then broaden when
touching public APIs, shader ABI, backend resource binding, or demo platforms.

| Path | Purpose |
| --- | --- |
| `src/core/` | Font, outline, blob, cache, and renderer-core internals. |
| `src/gpu/` | Backend-neutral resource model, mesh budgets, and shader stats. |
| `src/backends/` | Vulkan and Metal backend modules. |
| `shaders/` | Slang core modules, backend shims, and shader entries. |
| `demo/` | Native Win32, Wayland, and SwiftUI/AppKit demo hosts. |
| `build/`, `tools/` | Zig build helpers and Slang reflection layout generation. |

Use `zig fmt build.zig build/ demo/ src/ tools/` for Zig formatting. CI is
verification-only: formatting and script/YAML checks, core tests on
Ubuntu/macOS/Windows, shader compilation, Vulkan backend/demo build tests,
Swift format lint, and Metal backend/demo build tests on macOS.

## Credit

`heavy-slug` builds on Slug's practical GPU-side analytic glyph coverage and
recasts it around cubic blobs, h-band meshlets, and modern Vulkan/Metal APIs.

## License

MIT. See [LICENSE](LICENSE).
