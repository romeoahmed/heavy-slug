const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo/glfw.zig");
const demo_vk = @import("demo/vulkan.zig");
const pga = heavy_slug.pga;
const renderer_mod = heavy_slug.renderer;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) return error.VulkanNotSupported;

    const window = try glfw.createWindow(1280, 720, "heavy-slug demo");
    defer glfw.destroyWindow(window);

    var gctx = try demo_vk.GraphicsContext.init(window, allocator);
    defer gctx.deinit();

    try gctx.createSwapchain(window);

    // Init TextRenderer using the library's VulkanContext
    var text_renderer = try renderer_mod.TextRenderer.initFromContext(
        gctx.vulkan_ctx,
        gctx.surface_format.format,
        allocator,
        .{},
    );
    defer text_renderer.deinit();

    // Load fonts at different sizes
    const font_large = try text_renderer.loadFont("assets/Inter-Regular.otf", 48);
    const font_medium = try text_renderer.loadFont("assets/Inter-Regular.otf", 28);
    const font_small = try text_renderer.loadFont("assets/Inter-Regular.otf", 18);

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const frame = try gctx.beginFrame() orelse {
            try gctx.recreateSwapchain(window);
            continue;
        };

        const w: f32 = @floatFromInt(gctx.swapchain_extent.width);
        const h: f32 = @floatFromInt(gctx.swapchain_extent.height);
        const proj = orthoProjection(w, h);
        const viewport = [2]f32{ w, h };

        text_renderer.begin();

        // Title — centered near top
        try text_renderer.drawText(font_large, "heavy-slug",
            pga.Motor.fromTranslation(w * 0.5 - 140, h - 60),
            .{ 1.0, 1.0, 1.0, 1.0 });

        // Subtitle
        try text_renderer.drawText(font_medium, "GPU Text Rendering \xe2\x80\x94 Vulkan Mesh Shaders",
            pga.Motor.fromTranslation(w * 0.5 - 260, h - 110),
            .{ 0.6, 0.7, 0.9, 1.0 });

        // Static body text
        try text_renderer.drawText(font_small, "Slug algorithm: exact quadratic Bezier coverage",
            pga.Motor.fromTranslation(40, h - 180),
            .{ 0.8, 0.8, 0.8, 1.0 });
        try text_renderer.drawText(font_small, "HarfBuzz shaping \xe2\x80\xa2 FreeType outlines \xe2\x80\xa2 Zero-alloc render loop",
            pga.Motor.fromTranslation(40, h - 210),
            .{ 0.8, 0.8, 0.8, 1.0 });

        text_renderer.flush(frame.cmd, proj, viewport);

        try gctx.endFrame(frame);
    }
}

/// Orthographic projection: maps (0,0)..(w,h) to Vulkan clip space.
/// Origin at bottom-left, y increases upward.
/// Use motor y = h - offset_from_top for positions near the top.
fn orthoProjection(w: f32, h: f32) [4][4]f32 {
    return .{
        .{ 2.0 / w, 0, 0, 0 },
        .{ 0, -2.0 / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1, 1, 0, 1 },
    };
}
