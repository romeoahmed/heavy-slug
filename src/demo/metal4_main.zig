const std = @import("std");
const heavy_slug = @import("heavy_slug");
const heavy_slug_metal = @import("heavy_slug_metal");
const glfw = @import("glfw.zig");

const pga = heavy_slug.pga;

const lines = [_][]const u8{
    "Heavy Slug",
    "Metal 4 mesh shaders",
    "Slug glyph coverage via HarfBuzz GPU blobs",
};

fn orthoProjection(w: f32, h: f32) [4][4]f32 {
    return .{
        .{ 2.0 / w, 0, 0, 0 },
        .{ 0, -2.0 / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1, 1, 0, 1 },
    };
}

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(1280, 720, "heavy-slug Metal 4 demo");
    defer glfw.destroyWindow(window);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try heavy_slug_metal.Context.initForGlfwWindow(@ptrCast(window));
    defer ctx.deinit();

    var text_renderer = try heavy_slug_metal.TextRenderer.init(ctx, allocator, .{});
    defer text_renderer.deinit();

    const title_font = try text_renderer.loadFont("assets/Inter-Regular.otf", 64);
    const body_font = try text_renderer.loadFont("assets/Inter-Regular.otf", 28);

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const size = glfw.getFramebufferSize(window);
        if (size[0] == 0 or size[1] == 0) continue;

        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        text_renderer.begin();
        try text_renderer.drawText(
            title_font,
            lines[0],
            pga.Motor.fromTranslation(80, 120),
            .{ 0.95, 0.97, 1.0, 1.0 },
        );
        for (lines[1..], 0..) |line, i| {
            try text_renderer.drawText(
                body_font,
                line,
                pga.Motor.fromTranslation(84, 210 + @as(f32, @floatFromInt(i)) * 42),
                .{ 0.55, 0.82, 1.0, 1.0 },
            );
        }
        try text_renderer.flush(
            .{ size[0], size[1] },
            orthoProjection(w, h),
            .{ 0.05, 0.06, 0.075, 1.0 },
        );
    }
}
