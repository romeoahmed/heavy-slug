//! GPU glyph blob addressing used by current renderers.

pub const ResourceModel = enum {
    single_storage_buffer_offsets,
};

test "ResourceModel names current glyph resource strategy" {
    try @import("std").testing.expectEqual(@as(u2, 0), @intFromEnum(ResourceModel.single_storage_buffer_offsets));
}
