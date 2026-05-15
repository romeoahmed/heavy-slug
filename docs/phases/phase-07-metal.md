# Phase 07: Metal Backend and Objective-C++ Bridge

## Goal

Rebuild Metal around a precise C ABI bridge and the same renderer/frame contract as Vulkan.

## Tasks

1. Move Metal code under `src/backends/metal/`.
2. Split context, frame, glyph store, and renderer responsibilities.
3. Rewrite `bridge.h` with ownership comments for every handle.
4. Rewrite `bridge.mm` so frame completion drives resource retirement.
5. Keep Cocoa/GLFW setup in `src/demo/metal/`.

## Acceptance Criteria

- Metal implements the backend contract.
- Zig only sees C ABI handles.
- Borrowed host objects and retained bridge-owned objects are clearly separated.
- Normal glyph retirement does not require unconditional full-device waits.

## Verification

```bash
zig build test -Dmetal=true
zig build metal-shaders
zig build -Doptimize=ReleaseFast -Dmetal=true
zig build run -Ddemo=true -Ddemo-backend=metal4
```

## Dependencies

Phase 05.
