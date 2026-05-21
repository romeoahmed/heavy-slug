//! Core module surface and subsystem re-exports.

pub const types = @import("types.zig");
pub const units = @import("units.zig");
pub const errors = @import("errors.zig");
pub const protocol = @import("protocol.zig");
pub const font = @import("font/root.zig");
pub const outline = @import("outline/root.zig");
pub const blob = @import("blob/root.zig");
pub const cache = @import("cache/root.zig");
pub const render = @import("render/root.zig");

pub const Color = types.Color;
pub const Transform = types.Transform;
pub const View = types.View;
pub const PrecisionPolicy = types.PrecisionPolicy;
pub const PrecisionSelection = types.PrecisionSelection;
pub const PrecisionSelectionError = types.PrecisionSelectionError;
pub const FillRule = types.FillRule;
pub const FontHandle = types.FontHandle;
pub const FontSource = types.FontSource;
pub const FontOptions = types.FontOptions;
pub const Error = errors.Error;
pub const RendererOptions = render.RendererOptions;
pub const TextRun = render.TextRun;
pub const ScreenTextRun = render.ScreenTextRun;
pub const FrameToken = render.FrameToken;
pub const DrawTextResult = render.DrawTextResult;
pub const SubmitResult = render.SubmitResult;
pub const FrameDiagnostics = render.FrameDiagnostics;
pub const FrameWarning = render.FrameWarning;
pub const FrameWarnings = render.FrameWarnings;
pub const max_frame_warnings = render.max_frame_warnings;

test {
    _ = types;
    _ = units;
    _ = errors;
    _ = protocol;
    _ = font;
    _ = outline;
    _ = blob;
    _ = cache;
    _ = render;
}
