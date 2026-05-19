#pragma once

/*
 * Demo-only Cocoa window and Metal host bridge.
 *
 * All functions are main-thread-only. Returned Metal and Cocoa objects are
 * borrowed by Zig callers and remain valid until
 * hs_demo_cocoa_window_destroy().
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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
};

typedef struct hs_demo_cocoa_window hs_demo_cocoa_window;

typedef struct hs_demo_cocoa_utf8_span {
  const char *data;
  size_t len;
} hs_demo_cocoa_utf8_span;

typedef struct hs_demo_cocoa_error_buffer {
  char *data;
  size_t len;
} hs_demo_cocoa_error_buffer;

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

hs_demo_cocoa_window *
hs_demo_cocoa_window_create(uint32_t width, uint32_t height,
                            hs_demo_cocoa_utf8_span title,
                            hs_demo_cocoa_error_buffer error_buffer);

void hs_demo_cocoa_window_destroy(hs_demo_cocoa_window *host);
void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host);
void hs_demo_cocoa_window_snapshot(hs_demo_cocoa_window *host,
                                   hs_demo_cocoa_snapshot *snapshot);
double hs_demo_cocoa_window_time(hs_demo_cocoa_window *host);
void *hs_demo_cocoa_window_device(hs_demo_cocoa_window *host);
void *hs_demo_cocoa_window_command_queue(hs_demo_cocoa_window *host);
void *hs_demo_cocoa_window_layer(hs_demo_cocoa_window *host);

#ifdef __cplusplus
}
#endif
