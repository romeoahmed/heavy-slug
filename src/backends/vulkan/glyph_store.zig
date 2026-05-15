const heavy_slug = @import("heavy_slug");

pub const ResourceModel = heavy_slug.gpu.ResourceModel.bindless_storage_buffers;

test "Vulkan glyph store uses bindless storage-buffer resource model" {
    try @import("std").testing.expectEqual(heavy_slug.gpu.ResourceModel.bindless_storage_buffers, ResourceModel);
}
