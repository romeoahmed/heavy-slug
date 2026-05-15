const heavy_slug = @import("heavy_slug");

pub const ResourceModel = heavy_slug.gpu.ResourceModel.single_storage_buffer_offsets;

test "Metal glyph store uses single-buffer offset resource model" {
    try @import("std").testing.expectEqual(heavy_slug.gpu.ResourceModel.single_storage_buffer_offsets, ResourceModel);
}
