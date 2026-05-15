pub const abi = @import("abi.zig");
pub const resource_model = @import("resource_model.zig");

pub const ResourceModel = resource_model.ResourceModel;

test {
    _ = abi;
    _ = resource_model;
}
