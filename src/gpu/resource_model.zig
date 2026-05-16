//! Backend resource-addressing strategies used by current renderers.

pub const ResourceModel = enum {
    bindless_storage_buffers,
    single_storage_buffer_offsets,
};

test "ResourceModel names current backend resource strategies" {
    try @import("std").testing.expect(@intFromEnum(ResourceModel.bindless_storage_buffers) != @intFromEnum(ResourceModel.single_storage_buffer_offsets));
}
