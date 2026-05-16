pub const abi = @import("abi.zig");
pub const resource_model = @import("resource_model.zig");
pub const shader_stats = @import("shader_stats.zig");

pub const ResourceModel = resource_model.ResourceModel;
pub const ShaderStats = shader_stats.Snapshot;

test {
    _ = abi;
    _ = resource_model;
    _ = shader_stats;
}
