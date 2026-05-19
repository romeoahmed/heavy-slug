#pragma once

/*
 * Demo-only Cocoa window and Metal host bridge.
 *
 * All functions are main-thread-only. Returned Metal and Cocoa objects are
 * borrowed by Zig callers and remain valid until
 * hs_demo_cocoa_window_destroy().
 */

#include <stddef.h>
#include <stdint.h>

#ifndef __cplusplus
#include <uchar.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum {
  HS_DEMO_KEY_ESCAPE = 0,
  HS_DEMO_KEY_SPACE = 1,
  HS_DEMO_KEY_EQUAL = 2,
  HS_DEMO_KEY_MINUS = 3,
  HS_DEMO_KEY_B = 4,
  HS_DEMO_KEY_R = 5,
  HS_DEMO_KEY_UP = 6,
  HS_DEMO_KEY_DOWN = 7,
  HS_DEMO_KEY_LEFT = 8,
  HS_DEMO_KEY_RIGHT = 9,
  HS_DEMO_KEY_COUNT = 10,
};

enum {
  HS_DEMO_MOUSE_LEFT = 0,
  HS_DEMO_MOUSE_RIGHT = 1,
  HS_DEMO_MOUSE_COUNT = 2,
  HS_DEMO_COCOA_U8_SIZE = 1,
  HS_DEMO_COCOA_BOOL_SIZE = 1,
};

typedef enum hs_demo_cocoa_status : int {
  HS_DEMO_COCOA_STATUS_OK = 0,
  HS_DEMO_COCOA_STATUS_ERROR = 1,
} hs_demo_cocoa_status;
static_assert(sizeof(hs_demo_cocoa_status) == sizeof(int),
              "hs_demo_cocoa_status must match Zig enum(c_int)");

typedef struct hs_demo_cocoa_window hs_demo_cocoa_window;

typedef char8_t hs_demo_cocoa_u8;
static_assert(sizeof(hs_demo_cocoa_u8) == 1,
              "hs_demo_cocoa_u8 must be one byte");
static_assert(sizeof(bool) == HS_DEMO_COCOA_BOOL_SIZE,
              "C23 bool must match the Zig extern mirror");

typedef struct hs_demo_cocoa_u8_view {
  const hs_demo_cocoa_u8 *data;
  size_t size;
} hs_demo_cocoa_u8_view;
static_assert(offsetof(hs_demo_cocoa_u8_view, size) == sizeof(void *),
              "hs_demo_cocoa_u8_view must be pointer followed by size");
static_assert(sizeof(hs_demo_cocoa_u8_view) == sizeof(void *) + sizeof(size_t),
              "hs_demo_cocoa_u8_view must match the Zig extern mirror");

typedef struct hs_demo_cocoa_u8_buffer {
  hs_demo_cocoa_u8 *data;
  size_t size;
} hs_demo_cocoa_u8_buffer;
static_assert(offsetof(hs_demo_cocoa_u8_buffer, size) == sizeof(void *),
              "hs_demo_cocoa_u8_buffer must be pointer followed by size");
static_assert(sizeof(hs_demo_cocoa_u8_buffer) == sizeof(void *) + sizeof(size_t),
              "hs_demo_cocoa_u8_buffer must match the Zig extern mirror");

typedef struct hs_demo_cocoa_metal_host {
  /* Borrowed id<MTLDevice>. */
  void *device;
  /* Borrowed id<MTL4CommandQueue>. */
  void *command_queue;
  /* Borrowed CAMetalLayer*. */
  void *layer;
} hs_demo_cocoa_metal_host;
static_assert(sizeof(hs_demo_cocoa_metal_host) == 3 * sizeof(void *),
              "hs_demo_cocoa_metal_host must remain three borrowed object pointers");

typedef struct hs_demo_cocoa_snapshot {
  bool keys[HS_DEMO_KEY_COUNT];
  bool mouse_buttons[HS_DEMO_MOUSE_COUNT];
  double cursor_x;
  double cursor_y;
  double scroll_delta;
  uint32_t framebuffer_width;
  uint32_t framebuffer_height;
  bool should_close;
} hs_demo_cocoa_snapshot;

hs_demo_cocoa_status
hs_demo_cocoa_window_create(hs_demo_cocoa_window **out_window, uint32_t width,
                            uint32_t height,
                            hs_demo_cocoa_u8_view title,
                            hs_demo_cocoa_u8_buffer error_buffer);

void hs_demo_cocoa_window_destroy(hs_demo_cocoa_window *host);
void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host);
void hs_demo_cocoa_window_snapshot(hs_demo_cocoa_window *host,
                                   hs_demo_cocoa_snapshot *snapshot);
double hs_demo_cocoa_window_time(hs_demo_cocoa_window *host);
hs_demo_cocoa_metal_host
hs_demo_cocoa_window_metal_host(hs_demo_cocoa_window *host);

#ifdef __cplusplus
}
#endif
