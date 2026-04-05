# Build System + C Dependencies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile FreeType 2.14.3 and HarfBuzz 14.1.0 from upstream tarballs as static libraries via Zig's build system, with thin `@cImport` wrappers proving linkage works end-to-end.

**Architecture:** FreeType and HarfBuzz source tarballs are declared as lazy dependencies in `build.zig.zon`. Two standalone build functions (`buildFreetype`, `buildHarfbuzz`) in `build.zig` each return a `*Build.Step.Compile` static library artifact. The `heavy_slug` module links both artifacts and exposes their headers for `@cImport`. Thin Zig wrapper files (`src/font/ft.zig`, `src/font/hb.zig`) provide type-safe init/deinit around the C APIs with embedded tests.

**Tech Stack:** Zig 0.16.0-dev.3091+, FreeType 2.14.3, HarfBuzz 14.1.0 (with `libharfbuzz-gpu`)

**Spec:** `docs/superpowers/specs/2026-04-05-heavy-slug-design.md` — Sections 2 (Key Decisions: `@cImport`, HarfBuzz-GPU), 8.1 (build.zig.zon deps), 8.2 (C library compilation)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `build.zig.zon` | Modify | Add `freetype_src` and `harfbuzz_src` tarball dependencies |
| `build.zig` | Modify | Add `buildFreetype()`, `buildHarfbuzz()` functions; link artifacts + include paths to `heavy_slug` module |
| `src/font/ft.zig` | Create | `@cImport` wrapper for FreeType: `Library` struct with `init`/`deinit` |
| `src/font/hb.zig` | Create | `@cImport` wrapper for HarfBuzz: `Buffer` struct with `create`/`destroy`/`addUtf8`/`getLength` |
| `src/root.zig` | Modify | Re-export `font.ft` and `font.hb` as public submodules |

---

## Background: Zig Build System Patterns

This plan targets Zig 0.16.0-dev.3091+. Key patterns used:

- **`b.dependency("name", .{})`** — resolves a dependency declared in `build.zig.zon`, returns a `*Dependency` with a `.path()` method for accessing files within the dependency.
- **`b.addStaticLibrary(.{ .name = ..., .root_module = b.createModule(.{...}) })`** — creates a static library compile step. The `root_module` configures target, optimize, and link_libc.
- **`mod.addCSourceFiles(.{ .root = ..., .files = &.{...}, .flags = &.{...} })`** — compiles C/C++ sources. `.root` is a `LazyPath` base directory; `.files` are relative to it.
- **`mod.addIncludePath(path)`** — adds a header search path for `@cImport` and C compilation.
- **`mod.linkLibrary(artifact)`** — links a static library artifact into the module.
- **`@cImport({ @cInclude("header.h"); })`** — generates Zig bindings from C headers at compile time using the module's include paths.

If any API name has changed in your exact Zig version, compiler errors will be explicit about the correct name.

---

### Task 1: Fetch FreeType source tarball

**Files:**
- Modify: `build.zig.zon:34` (inside `.dependencies = .{`)

- [ ] **Step 1: Fetch FreeType and save to build.zig.zon**

Run:

```bash
zig fetch --save=freetype_src "https://nongnu.askapache.com/freetype/freetype-2.14.3.tar.gz"
```

Expected: command succeeds and `build.zig.zon` now has a `.freetype_src` entry with a populated `.hash` field inside `.dependencies`.

- [ ] **Step 2: Verify the dependency was added**

Run:

```bash
grep -A2 "freetype_src" build.zig.zon
```

Expected: output shows `.freetype_src = .{ .url = "...", .hash = "..." }` with a real hash (not a placeholder).

> **If the URL is unreachable:** FreeType mirrors change. Try `https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.gz` or `https://sourceforge.net/projects/freetype/files/freetype2/2.14.3/freetype-2.14.3.tar.gz/download` instead.

- [ ] **Step 3: Commit**

```bash
git add build.zig.zon
git commit -s -S -m "build: add FreeType 2.14.3 source dependency

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Build FreeType as a static library

**Files:**
- Modify: `build.zig` (add `buildFreetype` function + call it from `build()`)

- [ ] **Step 1: Add the `buildFreetype` function at the end of `build.zig`**

```zig
fn buildFreetype(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const ft_dep = b.dependency("freetype_src", .{});

    const lib = b.addStaticLibrary(.{
        .name = "freetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(ft_dep.path("include"));

    lib.root_module.addCSourceFiles(.{
        .root = ft_dep.path(""),
        .files = &.{
            "src/base/ftbase.c",
            "src/base/ftinit.c",
            "src/base/ftsystem.c",
            "src/base/ftdebug.c",
            "src/base/ftbbox.c",
            "src/base/ftbitmap.c",
            "src/base/ftglyph.c",
            "src/base/ftsynth.c",
            "src/base/ftstroke.c",
            "src/truetype/truetype.c",
            "src/cff/cff.c",
            "src/cid/type1cid.c",
            "src/type1/type1.c",
            "src/pfr/pfr.c",
            "src/sfnt/sfnt.c",
            "src/autofit/autofit.c",
            "src/pshinter/pshinter.c",
            "src/raster/raster.c",
            "src/smooth/smooth.c",
            "src/psaux/psaux.c",
            "src/psnames/psnames.c",
            "src/gzip/ftgzip.c",
            "src/lzw/ftlzw.c",
            "src/sdf/sdf.c",
            "src/svg/svg.c",
        },
        .flags = &.{
            "-DFT2_BUILD_LIBRARY",
        },
    });

    return lib;
}
```

> **Note on source files:** This is the standard FreeType 2.14.x compilation set. If a source file doesn't exist in your tarball (e.g. `src/svg/svg.c` was added in 2.13), remove it — the compiler error will name the exact missing file. If a required module is missing (link error for `FT_*` symbol), check `freetype-2.14.3/src/` for the directory containing the missing function and add its top-level `.c` file.

- [ ] **Step 2: Call `buildFreetype` from the `build()` function and link to the module**

Add this code in `build()`, immediately *after* the `const mod = b.addModule(...)` block and *before* the `const exe = b.addExecutable(...)` block:

```zig
    // --- C library compilation (spec §8.2) ---
    const ft_dep = b.dependency("freetype_src", .{});
    const ft_lib = buildFreetype(b, target, optimize);
    mod.linkLibrary(ft_lib);
    mod.addIncludePath(ft_dep.path("include"));
```

> **Why `addIncludePath` on `mod`?** `linkLibrary` handles the linker, but `@cImport` in Zig source files needs the headers visible at compile time. The explicit `addIncludePath` ensures `@cInclude("ft2build.h")` resolves.

- [ ] **Step 3: Verify FreeType compiles**

Run:

```bash
zig build
```

Expected: build succeeds with no errors. If you see "file not found" for a `.c` file, remove that entry from the `files` array. If you see a missing symbol at link time, find the FreeType module that provides it and add its `.c` file.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -s -S -m "build: compile FreeType 2.14.3 from source as static library

Add buildFreetype() function that compiles FreeType's standard module
set with -DFT2_BUILD_LIBRARY. Link artifact and include paths to the
heavy_slug module for @cImport access.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Create FreeType @cImport wrapper with tests

**Files:**
- Create: `src/font/ft.zig`

- [ ] **Step 1: Write the test first**

Create `src/font/ft.zig` with just the type signature and a test that uses it:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Error = error{
    InitFailed,
};

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        _ = @as(u0, 0); // placeholder — will be replaced in step 3
        return error.InitFailed;
    }

    pub fn deinit(self: Library) void {
        _ = self;
    }

    pub fn versionString(self: Library) struct { major: i32, minor: i32, patch: i32 } {
        _ = self;
        return .{ .major = 0, .minor = 0, .patch = 0 };
    }
};

test "init and deinit FreeType library" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.versionString();
    // FreeType 2.14.3 → major=2, minor=14, patch=3
    try std.testing.expectEqual(@as(i32, 2), ver.major);
    try std.testing.expect(ver.minor >= 14);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test 2>&1 | head -20
```

Expected: test fails (the placeholder `init` always returns `error.InitFailed`).

- [ ] **Step 3: Implement `Library` for real**

Replace the entire contents of `src/font/ft.zig` with:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Error = error{
    InitFailed,
};

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.InitFailed;
        return .{ .handle = lib };
    }

    pub fn deinit(self: Library) void {
        _ = c.FT_Done_FreeType(self.handle);
    }

    /// Returns the linked FreeType version (major, minor, patch).
    pub fn versionString(self: Library) struct { major: i32, minor: i32, patch: i32 } {
        var major: c.FT_Int = 0;
        var minor: c.FT_Int = 0;
        var patch: c.FT_Int = 0;
        c.FT_Library_Version(self.handle, &major, &minor, &patch);
        return .{ .major = major, .minor = minor, .patch = patch };
    }
};

test "init and deinit FreeType library" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.versionString();
    // FreeType 2.14.3 → major=2, minor=14, patch=3
    try std.testing.expectEqual(@as(i32, 2), ver.major);
    try std.testing.expect(ver.minor >= 14);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
zig build test 2>&1 | head -20
```

Expected: all tests pass, including the new FreeType test. If `FT_Int` doesn't match `i32`, the compiler will tell you the actual type — cast accordingly.

- [ ] **Step 5: Commit**

```bash
git add src/font/ft.zig
git commit -s -S -m "feat(font): add FreeType @cImport wrapper with init/deinit

Thin wrapper around FT_Init_FreeType / FT_Done_FreeType /
FT_Library_Version. Proves FreeType linkage works end-to-end.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Fetch HarfBuzz source tarball

**Files:**
- Modify: `build.zig.zon` (add `harfbuzz_src` dependency)

- [ ] **Step 1: Fetch HarfBuzz and save to build.zig.zon**

Run:

```bash
zig fetch --save=harfbuzz_src "https://github.com/harfbuzz/harfbuzz/releases/download/14.1.0/harfbuzz-14.1.0.tar.xz"
```

Expected: command succeeds and `build.zig.zon` now has a `.harfbuzz_src` entry with a populated `.hash` field.

- [ ] **Step 2: Verify the dependency was added**

Run:

```bash
grep -A2 "harfbuzz_src" build.zig.zon
```

Expected: output shows `.harfbuzz_src = .{ .url = "...", .hash = "..." }`.

- [ ] **Step 3: Commit**

```bash
git add build.zig.zon
git commit -s -S -m "build: add HarfBuzz 14.1.0 source dependency

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Build HarfBuzz as a static library

**Files:**
- Modify: `build.zig` (add `buildHarfbuzz` function + call it from `build()`)

HarfBuzz is C++ and requires linking libc++. It also depends on FreeType headers and the FreeType artifact. The GPU subsystem (`libharfbuzz-gpu`) is enabled via `-DHAVE_HB_GPU=1`.

- [ ] **Step 1: Add the `buildHarfbuzz` function at the end of `build.zig`**

```zig
fn buildHarfbuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ft_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const hb_dep = b.dependency("harfbuzz_src", .{});
    const ft_dep = b.dependency("freetype_src", .{});

    const lib = b.addStaticLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // HarfBuzz headers + internal headers live in src/
    lib.root_module.addIncludePath(hb_dep.path("src"));
    // HarfBuzz needs FreeType headers for HAVE_FREETYPE
    lib.root_module.addIncludePath(ft_dep.path("include"));
    // Link FreeType so HarfBuzz can call FT_* functions
    lib.root_module.linkLibrary(ft_lib);

    // Core: unity build (includes all non-GPU HarfBuzz source)
    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{
            "harfbuzz.cc",
        },
        .flags = &.{
            "-DHAVE_FREETYPE=1",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });

    // GPU subsystem (spec §8.2: -DHAVE_HB_GPU=1)
    // These files may already be included in the unity build when HAVE_HB_GPU
    // is set. If you get duplicate symbol errors, remove this block.
    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{
            "hb-gpu-draw.cc",
            "hb-gpu-shaders.cc",
        },
        .flags = &.{
            "-DHAVE_FREETYPE=1",
            "-DHAVE_HB_GPU=1",
            "-fno-exceptions",
            "-fno-rtti",
        },
    });

    return lib;
}
```

> **Duplicate symbols?** If linking fails with duplicate symbol errors from the GPU files, the unity build (`harfbuzz.cc`) already includes them when `HAVE_HB_GPU` is set. In that case: (1) remove the second `addCSourceFiles` block for the GPU files, and (2) add `-DHAVE_HB_GPU=1` to the flags on the first (unity) `addCSourceFiles` block.
>
> **GPU files don't exist?** If `hb-gpu-draw.cc` or `hb-gpu-shaders.cc` are not found in `src/`, the HarfBuzz 14.1.0 tarball may have a different directory structure for GPU support. Run `find $(zig env | jq -r .global_cache_dir)/p/<hash> -name "hb-gpu*"` (substitute the actual hash from build.zig.zon) to locate the files.

- [ ] **Step 2: Call `buildHarfbuzz` from `build()` and link to the module**

In `build()`, extend the C library block (added in Task 2, Step 2) to also build and link HarfBuzz:

```zig
    // --- C library compilation (spec §8.2) ---
    const ft_dep = b.dependency("freetype_src", .{});
    const hb_dep = b.dependency("harfbuzz_src", .{});
    const ft_lib = buildFreetype(b, target, optimize);
    const hb_lib = buildHarfbuzz(b, target, optimize, ft_lib);
    mod.linkLibrary(ft_lib);
    mod.linkLibrary(hb_lib);
    mod.addIncludePath(ft_dep.path("include"));
    mod.addIncludePath(hb_dep.path("src"));
```

This replaces the previous block from Task 2 Step 2 (which only had FreeType). The two new lines are `hb_dep`, `hb_lib`, `mod.linkLibrary(hb_lib)`, and `mod.addIncludePath(hb_dep.path("src"))`.

- [ ] **Step 3: Verify HarfBuzz compiles**

Run:

```bash
zig build
```

Expected: build succeeds. Common issues:
- **Missing `hb-gpu-*.cc`**: see note above about locating GPU files.
- **Duplicate symbols**: see note above about unity build already including GPU files.
- **Missing `<cstdlib>` or similar C++ headers**: ensure `link_libcpp = true` is set.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -s -S -m "build: compile HarfBuzz 14.1.0 from source as static library

Add buildHarfbuzz() function that compiles the HarfBuzz unity build
(harfbuzz.cc) plus GPU subsystem files with -DHAVE_FREETYPE=1 and
-DHAVE_HB_GPU=1. Links FreeType artifact. Both libraries linked to
the heavy_slug module.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Create HarfBuzz @cImport wrapper with tests

**Files:**
- Create: `src/font/hb.zig`

- [ ] **Step 1: Write the test first**

Create `src/font/hb.zig` with type stubs and tests that will fail:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("hb.h");
});

pub const Error = error{
    BufferCreateFailed,
    AllocationFailed,
};

pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    pub fn create() Error!Buffer {
        return error.BufferCreateFailed; // placeholder
    }

    pub fn destroy(self: Buffer) void {
        _ = self;
    }

    pub fn addUtf8(self: Buffer, text: []const u8) void {
        _ = self;
        _ = text;
    }

    pub fn getLength(self: Buffer) u32 {
        _ = self;
        return 0;
    }
};

test "create and destroy HarfBuzz buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
}

test "add UTF-8 text to buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.addUtf8("hello");
    try std.testing.expectEqual(@as(u32, 5), buf.getLength());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
zig build test 2>&1 | head -20
```

Expected: test fails (placeholder `create` always returns `error.BufferCreateFailed`).

- [ ] **Step 3: Implement `Buffer` for real**

Replace the entire contents of `src/font/hb.zig` with:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("hb.h");
});

pub const Error = error{
    BufferCreateFailed,
    AllocationFailed,
};

pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    pub fn create() Error!Buffer {
        const buf = c.hb_buffer_create() orelse return error.BufferCreateFailed;
        if (c.hb_buffer_allocation_successful(buf) == 0) {
            c.hb_buffer_destroy(buf);
            return error.AllocationFailed;
        }
        return .{ .handle = buf };
    }

    pub fn destroy(self: Buffer) void {
        c.hb_buffer_destroy(self.handle);
    }

    pub fn addUtf8(self: Buffer, text: []const u8) void {
        c.hb_buffer_add_utf8(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    pub fn getLength(self: Buffer) u32 {
        return c.hb_buffer_get_length(self.handle);
    }

    pub fn setDirection(self: Buffer, dir: c.hb_direction_t) void {
        c.hb_buffer_set_direction(self.handle, dir);
    }

    pub fn setScript(self: Buffer, script: c.hb_script_t) void {
        c.hb_buffer_set_script(self.handle, script);
    }
};

/// Re-export C constants for callers that need direction/script values.
pub const Direction = c.hb_direction_t;
pub const Script = c.hb_script_t;
pub const HB_DIRECTION_LTR = c.HB_DIRECTION_LTR;
pub const HB_SCRIPT_LATIN = c.HB_SCRIPT_LATIN;

test "create and destroy HarfBuzz buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
}

test "add UTF-8 text to buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.addUtf8("hello");
    try std.testing.expectEqual(@as(u32, 5), buf.getLength());
}

test "set direction and script" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.setDirection(c.HB_DIRECTION_LTR);
    buf.setScript(c.HB_SCRIPT_LATIN);
    buf.addUtf8("test");
    try std.testing.expectEqual(@as(u32, 4), buf.getLength());
}
```

> **Type mismatch on `hb_buffer_create` return?** If `@cImport` translates the return type as a non-optional pointer (`*c.hb_buffer_t` instead of `?*c.hb_buffer_t`), remove the `orelse return error.BufferCreateFailed` and assign directly. The allocation check via `hb_buffer_allocation_successful` is the real guard.
>
> **`hb_bool_t` type?** `hb_buffer_allocation_successful` returns `hb_bool_t` which is a `c_int`. If the `== 0` comparison doesn't compile, try `== @as(c.hb_bool_t, 0)`.

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
zig build test 2>&1 | head -20
```

Expected: all tests pass — the three new HarfBuzz tests plus the FreeType test from Task 3.

- [ ] **Step 5: Commit**

```bash
git add src/font/hb.zig
git commit -s -S -m "feat(font): add HarfBuzz @cImport wrapper with buffer operations

Thin wrapper around hb_buffer_create / hb_buffer_destroy /
hb_buffer_add_utf8 / hb_buffer_get_length. Includes direction and
script setters. Proves HarfBuzz linkage works end-to-end.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Re-export font modules from root.zig and verify full build

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add font module re-exports to `src/root.zig`**

Add these lines at the top of `src/root.zig`, after the existing imports:

```zig
pub const ft = @import("font/ft.zig");
pub const hb = @import("font/hb.zig");
```

Keep the existing `printAnotherMessage`, `add`, and test code — they still work and provide a baseline.

The full file should now look like:

```zig
//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ft = @import("font/ft.zig");
pub const hb = @import("font/hb.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
```

- [ ] **Step 2: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass — the original `basic add functionality` test, the FreeType `init and deinit` test, and the three HarfBuzz buffer tests. Total: 5 tests passing.

- [ ] **Step 3: Verify the library builds**

Run:

```bash
zig build
```

Expected: clean build, no warnings, no errors.

- [ ] **Step 4: Verify the executable still runs**

Run:

```bash
zig build run
```

Expected: prints `All your codebase are belong to us.` and `Run "zig build test" to run the tests.` (same as before — we haven't changed main.zig).

- [ ] **Step 5: Commit**

```bash
git add src/root.zig
git commit -s -S -m "feat: re-export font.ft and font.hb from library root

The heavy_slug module now exposes FreeType and HarfBuzz wrappers as
public submodules, making them available to downstream consumers.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Task |
|-----------------|------|
| §8.1: `freetype_src` in `build.zig.zon` | Task 1 |
| §8.1: `harfbuzz_src` in `build.zig.zon` | Task 4 |
| §8.2: `buildFreetype()` returning `*Build.Step.Compile` | Task 2 |
| §8.2: `buildHarfbuzz()` returning `*Build.Step.Compile` | Task 5 |
| §8.2: HarfBuzz configured with `-DHAVE_FREETYPE=1` | Task 5 |
| §8.2: HarfBuzz links FreeType artifact | Task 5 |
| §8.2: HarfBuzz built with `-DHAVE_HB_GPU=1` | Task 5 |
| §8.2: HarfBuzz GPU sources (`hb-gpu-draw.cc`, `hb-gpu-shaders.cc`) | Task 5 |
| §2: Direct C API via `@cImport` | Tasks 3, 6 |
| §4: `src/font/ft.zig` — FreeType @cImport + error set | Task 3 |
| §4: `src/font/hb.zig` — HarfBuzz @cImport + error set | Task 6 |

**Not in scope for this plan** (deferred to later plans):
- §8.1: `zmath`, `zgpu` dependencies (Plan 5: Render Pipeline)
- §8.3: Slang / SlangReflectStep / LayoutGenStep / SlangCompileStep (Plan 3: Shader Pipeline)
- §4: `src/font/glyph.zig` — FT face loader + metrics (Plan 2: Math + Font)
- §4: `src/font/hb.zig` — `hb_gpu_draw` wrappers (Plan 2: Math + Font, or Plan 4: GPU Atlas)

### Placeholder scan

No TBD, TODO, "implement later", "fill in details", "add appropriate error handling", or "similar to Task N" found.

### Type consistency

- `buildFreetype` signature: `(b, target, optimize) → *Compile` — used in Task 2 Step 2 ✓
- `buildHarfbuzz` signature: `(b, target, optimize, ft_lib) → *Compile` — used in Task 5 Step 2 ✓
- `ft.Library` struct: used consistently in Task 3 (init/deinit/versionString) ✓
- `hb.Buffer` struct: used consistently in Task 6 (create/destroy/addUtf8/getLength/setDirection/setScript) ✓
- `ft_dep`, `hb_dep` declared in `build()` scope in Task 5 Step 2, not conflicting with local declarations inside `buildFreetype`/`buildHarfbuzz` ✓
