#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GLFWwindow GLFWwindow;
typedef struct hs_metal_context hs_metal_context;
typedef struct hs_metal_buffer hs_metal_buffer;

hs_metal_context *hs_metal_context_create_from_cocoa_window(
    void *ns_window,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len);

hs_metal_context *hs_metal_context_create_from_glfw_window(
    GLFWwindow *window,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len);

void hs_metal_context_destroy(hs_metal_context *context);

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
    char *error_buffer,
    size_t error_buffer_len);

#ifdef __cplusplus
}
#endif
