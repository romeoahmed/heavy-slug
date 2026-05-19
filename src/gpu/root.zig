//! Backend-neutral GPU ABI and diagnostics.

pub const abi = @import("abi.zig");
pub const mesh_limits = @import("mesh_limits.zig");
pub const resource_model = @import("resource_model.zig");
pub const shader_stats = @import("shader_stats.zig");

pub const MeshLimits = mesh_limits;
pub const ResourceModel = resource_model.ResourceModel;
pub const BufferBinding = resource_model.BufferBinding;
pub const ShaderStats = shader_stats.Stats;

test {
    _ = abi;
    _ = mesh_limits;
    _ = resource_model;
    _ = shader_stats;
}
