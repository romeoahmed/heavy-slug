#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hs_metal_context hs_metal_context;
typedef struct hs_metal_pipeline hs_metal_pipeline;
typedef struct hs_metal_buffer hs_metal_buffer;
typedef struct hs_metal_frame hs_metal_frame;
typedef struct hs_metal_target hs_metal_target;

typedef struct hs_metal_host_objects {
    /* Borrowed id<MTLDevice>; caller retains ownership and must outlive context. */
    void *device;
    /* Borrowed id<MTLCommandQueue>; caller retains ownership and must outlive context. */
    void *command_queue;
    /* Borrowed CAMetalLayer*; caller retains ownership and must outlive context. */
    void *layer;
} hs_metal_host_objects;

/*
 * Ownership model:
 * - create/destroy pairs transfer ownership of hs_metal_context and hs_metal_buffer.
 * - Host Objective-C objects are borrowed unless a function name explicitly says retain.
 * - The context owns its internal pipeline, frame slots, target/drawable state, and
 *   completion handlers. Zig sees only typed opaque C handles.
 * - Errors cross the ABI as a boolean status plus caller-provided UTF-8 text buffer.
 */
hs_metal_context *hs_metal_context_create(
    hs_metal_host_objects host,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len);

void hs_metal_context_destroy(hs_metal_context *context);
int hs_metal_context_wait_frame_slot(
    hs_metal_context *context,
    uint32_t slot_index,
    char *error_buffer,
    size_t error_buffer_len);
void hs_metal_context_release_frame_slot(hs_metal_context *context, uint32_t slot_index);
void hs_metal_context_wait_submitted(hs_metal_context *context);

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context, size_t size);
void hs_metal_buffer_destroy(hs_metal_buffer *buffer);
void *hs_metal_buffer_contents(hs_metal_buffer *buffer);

int hs_metal_context_draw(
    hs_metal_context *context,
    uint32_t width,
    uint32_t height,
    float clear_r,
    float clear_g,
    float clear_b,
    float clear_a,
    hs_metal_buffer *commands,
    hs_metal_buffer *push_constants,
    hs_metal_buffer *glyph_pool,
    uint32_t workgroup_count,
    uint32_t slot_index,
    char *error_buffer,
    size_t error_buffer_len);

#ifdef __cplusplus
}
#endif
