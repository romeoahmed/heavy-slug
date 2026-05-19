#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef HEAVY_SLUG_SHADER_STATS
#define HEAVY_SLUG_SHADER_STATS 0
#endif

typedef struct hs_metal_context hs_metal_context;
typedef struct hs_metal_buffer hs_metal_buffer;

typedef struct hs_metal_host_objects {
  /* Borrowed id<MTLDevice>; retained by the created context. */
  void *device;
  /* Borrowed id<MTL4CommandQueue>; retained by the context and must belong to device. */
  void *command_queue;
  /*
   * Borrowed CAMetalLayer*; retained by the context. Its device must match
   * device, its Metal 4 residencySet must be available, and its pixelFormat is
   * baked into the Metal render pipeline. The layer must stay attached and
   * configured for presentation while drawing.
   */
  void *layer;
} hs_metal_host_objects;

typedef struct hs_metal_resource_indices {
  uint32_t glyph_pool;
  uint32_t glyphs;
  uint32_t meshlets;
  uint32_t frame_params;
  uint32_t shader_stats;
} hs_metal_resource_indices;

typedef struct hs_metal_geometry_limits {
  /* Zero when the Metal path has no object shader stage. */
  uint32_t object_threadgroup_size;
  uint32_t mesh_threadgroup_size;
  uint32_t max_mesh_threadgroups_per_draw;
} hs_metal_geometry_limits;

/*
 * Keep these indices in lockstep with shaders/backend_metal/resources.slang
 * and the generated MSL argument table.
 */
enum {
  HS_METAL_BUFFER_GLYPH_POOL = 0,
  HS_METAL_BUFFER_GLYPHS = 1,
  HS_METAL_BUFFER_MESHLETS = 2,
  HS_METAL_BUFFER_FRAME_PARAMS = HEAVY_SLUG_SHADER_STATS ? 4 : 3,
  HS_METAL_BUFFER_SHADER_STATS = 3,
  /*
   * Keep geometry limits in lockstep with shaders/core/abi.slang
   * and src/gpu/mesh_limits.zig.
   */
  HS_METAL_OBJECT_THREADGROUP_SIZE = 0,
  HS_METAL_MESH_THREADGROUP_SIZE = 32,
  HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW = 1024,
};

hs_metal_resource_indices hs_metal_get_resource_indices(void);
hs_metal_geometry_limits hs_metal_get_geometry_limits(void);

/*
 * Ownership model:
 * - create/destroy pairs transfer ownership of hs_metal_context and
 * hs_metal_buffer.
 * - Host Objective-C objects are borrowed at creation and retained internally.
 * - hs_metal_buffer objects are owned by callers and must not outlive their
 *   context.
 * - The context owns its internal pipeline, frame slots, argument tables, and
 *   completion handlers. Zig sees only typed opaque C handles.
 * - Errors cross the ABI as a boolean status plus caller-provided UTF-8 text
 * buffer.
 */
hs_metal_context *
hs_metal_context_create(hs_metal_host_objects host, const char *mesh_source,
                        size_t mesh_source_len, const char *fragment_source,
                        size_t fragment_source_len, char *error_buffer,
                        size_t error_buffer_len);

void hs_metal_context_destroy(hs_metal_context *context);
int hs_metal_context_wait_frame_slot(hs_metal_context *context,
                                     uint32_t slot_index, char *error_buffer,
                                     size_t error_buffer_len);
void hs_metal_context_release_frame_slot(hs_metal_context *context,
                                         uint32_t slot_index);
void hs_metal_context_wait_submitted(hs_metal_context *context);

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context, size_t size);
void hs_metal_buffer_destroy(hs_metal_buffer *buffer);
void *hs_metal_buffer_contents(hs_metal_buffer *buffer);

int hs_metal_context_draw(hs_metal_context *context, uint32_t width,
                          uint32_t height, float clear_r, float clear_g,
                          float clear_b, float clear_a, hs_metal_buffer *glyphs,
                          hs_metal_buffer *meshlets,
                          hs_metal_buffer *frame_params,
                          uint32_t frame_params_stride,
                          hs_metal_buffer *glyph_pool,
                          hs_metal_buffer *shader_stats,
                          uint32_t workgroup_count, uint32_t slot_index,
                          char *error_buffer, size_t error_buffer_len);

#ifdef __cplusplus
}
#endif
