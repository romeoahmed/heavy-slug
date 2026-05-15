#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GLFWwindow GLFWwindow;
typedef struct hs_demo_metal_host hs_demo_metal_host;

hs_demo_metal_host *hs_demo_metal_host_create(
    GLFWwindow *window,
    char *error_buffer,
    size_t error_buffer_len);

void hs_demo_metal_host_destroy(hs_demo_metal_host *host);
void *hs_demo_metal_host_device(hs_demo_metal_host *host);
void *hs_demo_metal_host_command_queue(hs_demo_metal_host *host);
void *hs_demo_metal_host_layer(hs_demo_metal_host *host);

#ifdef __cplusplus
}
#endif
