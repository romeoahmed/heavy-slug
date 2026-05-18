// Cocoa window and Metal demo host functions exposed to Zig.

#include "cocoa.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <utility>

@class HeavySlugDemoView;
@class HeavySlugDemoWindowDelegate;
@class HeavySlugDemoAppDelegate;

static NSString *const HeavySlugAppName = @"heavy-slug";
static NSString *const HeavySlugFallbackTitle = @"heavy-slug Metal 4 demo";

namespace {

constexpr double kPreciseScrollScale = 0.1;

enum class DemoKey : int {
  escape = HS_DEMO_KEY_ESCAPE,
  space = HS_DEMO_KEY_SPACE,
  equal = HS_DEMO_KEY_EQUAL,
  minus = HS_DEMO_KEY_MINUS,
  b = HS_DEMO_KEY_B,
  r = HS_DEMO_KEY_R,
  up = HS_DEMO_KEY_UP,
  down = HS_DEMO_KEY_DOWN,
  left = HS_DEMO_KEY_LEFT,
  right = HS_DEMO_KEY_RIGHT,
};

enum class MouseButton : int {
  left = HS_DEMO_MOUSE_LEFT,
  right = HS_DEMO_MOUSE_RIGHT,
};

static_assert(HS_DEMO_KEY_COUNT == 10);
static_assert(HS_DEMO_MOUSE_COUNT == 2);

[[nodiscard]] constexpr std::size_t keyIndex(DemoKey key) noexcept {
  return static_cast<std::size_t>(std::to_underlying(key));
}

[[nodiscard]] constexpr std::size_t mouseIndex(MouseButton button) noexcept {
  return static_cast<std::size_t>(std::to_underlying(button));
}

} // namespace

struct hs_demo_cocoa_window {
  __strong NSWindow *window = nil;
  __strong HeavySlugDemoView *view = nil;
  __strong HeavySlugDemoWindowDelegate *delegate = nil;
  __strong id<MTLDevice> device = nil;
  __strong id<MTL4CommandQueue> command_queue = nil;
  __strong CAMetalLayer *layer = nil;
  std::array<bool, HS_DEMO_KEY_COUNT> keys{};
  std::array<bool, HS_DEMO_MOUSE_COUNT> mouse_buttons{};
  double cursor_x = 0;
  double cursor_y = 0;
  double scroll_delta = 0;
  std::uint32_t framebuffer_width = 0;
  std::uint32_t framebuffer_height = 0;
  bool should_close = false;
  CFTimeInterval start_time = 0;

  hs_demo_cocoa_window(id<MTLDevice> device_,
                       id<MTL4CommandQueue> command_queue_) noexcept
      : device(device_), command_queue(command_queue_),
        start_time(CACurrentMediaTime()) {}

  hs_demo_cocoa_window(const hs_demo_cocoa_window &) = delete;
  hs_demo_cocoa_window &operator=(const hs_demo_cocoa_window &) = delete;
};

@interface HeavySlugDemoAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *activeHost;
@end

namespace {

struct CocoaAppState final {
  __strong HeavySlugDemoAppDelegate *delegate = nil;
  bool finished_launching = false;
  bool menu_installed = false;
};

[[nodiscard]] CocoaAppState &appState() noexcept {
  static CocoaAppState state;
  return state;
}

class ErrorSink final {
public:
  explicit ErrorSink(std::span<char> buffer) noexcept : buffer_(buffer) {}

  void write(NSString *message) const {
    if (buffer_.empty())
      return;
    const char *text =
        message ? [message UTF8String] : "unknown Cocoa host error";
    std::snprintf(buffer_.data(), buffer_.size(), "%s", text);
  }

  void write(NSString *prefix, NSError *error) const {
    if (error.localizedDescription.length > 0) {
      write([NSString
          stringWithFormat:@"%@: %@", prefix, error.localizedDescription]);
      return;
    }
    write(prefix);
  }

private:
  std::span<char> buffer_;
};

[[nodiscard]] std::span<char> errorBuffer(char *buffer,
                                          std::size_t len) noexcept {
  if (buffer == nullptr || len == 0)
    return {};
  return {buffer, len};
}

[[nodiscard]] bool requireMainThread(const ErrorSink &error) {
  if ([NSThread isMainThread])
    return true;
  error.write(@"Cocoa demo host must be created on the main thread");
  return false;
}

void clearInput(hs_demo_cocoa_window *host) {
  if (!host)
    return;
  host->keys.fill(false);
  host->mouse_buttons.fill(false);
  host->scroll_delta = 0;
}

[[nodiscard]] std::uint32_t pixelDimension(CGFloat value) {
  if (!std::isfinite(value) || value <= 0)
    return 0;
  constexpr auto max_dimension =
      static_cast<CGFloat>(std::numeric_limits<std::uint32_t>::max());
  if (value >= max_dimension)
    return std::numeric_limits<std::uint32_t>::max();
  return static_cast<std::uint32_t>(std::llround(value));
}

[[nodiscard]] CGFloat contentsScaleForBounds(NSRect logical_bounds,
                                             NSRect backing_bounds,
                                             NSWindow *window) {
  CGFloat scale_x = 0;
  CGFloat scale_y = 0;
  if (logical_bounds.size.width > 0)
    scale_x = backing_bounds.size.width / logical_bounds.size.width;
  if (logical_bounds.size.height > 0)
    scale_y = backing_bounds.size.height / logical_bounds.size.height;

  CGFloat scale = std::max(scale_x, scale_y);
  if (std::isfinite(scale) && scale > 0)
    return scale;

  if (window) {
    CGFloat fallback = window.backingScaleFactor;
    if (std::isfinite(fallback) && fallback > 0)
      return fallback;
  }
  return 1;
}

void updateDrawableSize(hs_demo_cocoa_window *host) {
  if (!host || !host->window || !host->view || !host->layer)
    return;
  NSView *view = (NSView *)host->view;
  NSRect logical_bounds = view.bounds;
  host->layer.frame = logical_bounds;

  if (logical_bounds.size.width <= 0 || logical_bounds.size.height <= 0) {
    host->layer.drawableSize = CGSizeZero;
    host->framebuffer_width = 0;
    host->framebuffer_height = 0;
    return;
  }

  NSRect backing_bounds = [view convertRectToBacking:logical_bounds];
  std::uint32_t pixel_width = pixelDimension(backing_bounds.size.width);
  std::uint32_t pixel_height = pixelDimension(backing_bounds.size.height);
  host->layer.contentsScale =
      contentsScaleForBounds(logical_bounds, backing_bounds, host->window);
  host->layer.drawableSize =
      CGSizeMake((CGFloat)pixel_width, (CGFloat)pixel_height);
  host->framebuffer_width = pixel_width;
  host->framebuffer_height = pixel_height;
}

[[nodiscard]] std::optional<DemoKey> keyForCharacter(unichar character) {
  switch (character) {
  case 0x1b:
    return DemoKey::escape;
  case ' ':
    return DemoKey::space;
  case '=':
  case '+':
    return DemoKey::equal;
  case '-':
  case '_':
    return DemoKey::minus;
  case 'b':
  case 'B':
    return DemoKey::b;
  case 'r':
  case 'R':
    return DemoKey::r;
  case NSUpArrowFunctionKey:
    return DemoKey::up;
  case NSDownArrowFunctionKey:
    return DemoKey::down;
  case NSLeftArrowFunctionKey:
    return DemoKey::left;
  case NSRightArrowFunctionKey:
    return DemoKey::right;
  default:
    return std::nullopt;
  }
}

[[nodiscard]] std::optional<DemoKey> keyForEvent(NSEvent *event) {
  NSString *characters = event.charactersIgnoringModifiers;
  if (characters.length == 0)
    return std::nullopt;
  return keyForCharacter([characters characterAtIndex:0]);
}

void setKey(hs_demo_cocoa_window *host, DemoKey key, bool pressed) {
  host->keys[keyIndex(key)] = pressed;
}

void setMouseButton(hs_demo_cocoa_window *host, MouseButton button,
                    bool pressed) {
  host->mouse_buttons[mouseIndex(button)] = pressed;
}

template <std::size_t Count>
void copyBoolState(const std::array<bool, Count> &source,
                   bool (&destination)[Count]) {
  std::copy(source.cbegin(), source.cend(),
            std::span<bool, Count>{destination}.begin());
}

[[nodiscard]] NSString *windowTitle(const char *title) {
  if (title == nullptr || title[0] == '\0')
    return HeavySlugFallbackTitle;
  NSString *title_string = [NSString stringWithUTF8String:title];
  return title_string ? title_string : HeavySlugFallbackTitle;
}

[[nodiscard]] double normalizedScrollDelta(NSEvent *event) {
  double delta = event.scrollingDeltaY;
  if (event.hasPreciseScrollingDeltas)
    return delta * kPreciseScrollScale;
  return delta;
}

[[nodiscard]] NSMenuItem *menuItem(NSString *title, SEL action, NSString *key,
                                   id target) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:key];
  item.target = target;
  if (key.length > 0)
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  return item;
}

void installMainMenu(void) {
  CocoaAppState &state = appState();
  if (state.menu_installed)
    return;

  NSMenu *main_menu = [[NSMenu alloc] initWithTitle:@""];

  NSMenuItem *app_menu_item = [[NSMenuItem alloc] initWithTitle:@""
                                                         action:nil
                                                  keyEquivalent:@""];
  NSMenu *app_menu = [[NSMenu alloc] initWithTitle:HeavySlugAppName];
  [app_menu
      addItem:menuItem(@"About heavy-slug",
                       @selector(orderFrontStandardAboutPanel:), @"", NSApp)];
  [app_menu addItem:[NSMenuItem separatorItem]];
  [app_menu
      addItem:menuItem(@"Quit heavy-slug", @selector(terminate:), @"q", NSApp)];
  app_menu_item.submenu = app_menu;
  [main_menu addItem:app_menu_item];

  NSMenuItem *file_menu_item = [[NSMenuItem alloc] initWithTitle:@""
                                                          action:nil
                                                   keyEquivalent:@""];
  NSMenu *file_menu = [[NSMenu alloc] initWithTitle:@"File"];
  [file_menu
      addItem:menuItem(@"Close Window", @selector(performClose:), @"w", nil)];
  file_menu_item.submenu = file_menu;
  [main_menu addItem:file_menu_item];

  NSApp.mainMenu = main_menu;
  state.menu_installed = true;
}

} // namespace

@implementation HeavySlugDemoAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication *)sender {
  (void)sender;
  if (self.activeHost) {
    self.activeHost->should_close = true;
    clearInput(self.activeHost);
    return NSTerminateCancel;
  }
  return NSTerminateNow;
}

- (void)applicationDidResignActive:(NSNotification *)notification {
  (void)notification;
  clearInput(self.activeHost);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
    (NSApplication *)sender {
  (void)sender;
  return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)flag {
  (void)flag;
  if (!self.activeHost || self.activeHost->should_close)
    return NO;
  [self.activeHost->window deminiaturize:nil];
  [self.activeHost->window makeKeyAndOrderFront:nil];
  [sender activate];
  return YES;
}

@end

@interface HeavySlugDemoView : NSView
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@property(nonatomic, strong) NSTrackingArea *mouseTrackingArea;
@end

@implementation HeavySlugDemoView

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)dealloc {
  if (_mouseTrackingArea)
    [self removeTrackingArea:_mouseTrackingArea];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window)
    [self.window makeFirstResponder:self];
  [self updateTrackingAreas];
  updateDrawableSize(self.host);
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  updateDrawableSize(self.host);
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  updateDrawableSize(self.host);
}

- (void)setBoundsSize:(NSSize)newSize {
  [super setBoundsSize:newSize];
  updateDrawableSize(self.host);
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.mouseTrackingArea) {
    [self removeTrackingArea:self.mouseTrackingArea];
    self.mouseTrackingArea = nil;
  }

  NSTrackingAreaOptions options =
      NSTrackingMouseMoved | NSTrackingCursorUpdate |
      NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
      NSTrackingEnabledDuringMouseDrag;
  self.mouseTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                        options:options
                                                          owner:self
                                                       userInfo:nil];
  [self addTrackingArea:self.mouseTrackingArea];
}

- (void)cursorUpdate:(NSEvent *)event {
  (void)event;
  [[NSCursor arrowCursor] set];
}

- (void)recordCursor:(NSEvent *)event {
  if (!self.host)
    return;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  self.host->cursor_x = point.x;
  self.host->cursor_y = point.y;
}

- (void)keyDown:(NSEvent *)event {
  if (!self.host) {
    [super keyDown:event];
    return;
  }
  if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
    [super keyDown:event];
    return;
  }

  std::optional<DemoKey> key = keyForEvent(event);
  if (key) {
    setKey(self.host, *key, true);
    return;
  }
  [super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
  if (!self.host) {
    [super keyUp:event];
    return;
  }
  std::optional<DemoKey> key = keyForEvent(event);
  if (key) {
    setKey(self.host, *key, false);
    return;
  }
  [super keyUp:event];
}

- (void)mouseDown:(NSEvent *)event {
  [self recordCursor:event];
  if (!self.host)
    return;
  setMouseButton(self.host, MouseButton::left, true);
}

- (void)mouseUp:(NSEvent *)event {
  [self recordCursor:event];
  if (!self.host)
    return;
  setMouseButton(self.host, MouseButton::left, false);
}

- (void)rightMouseDown:(NSEvent *)event {
  [self recordCursor:event];
  if (!self.host)
    return;
  setMouseButton(self.host, MouseButton::right, true);
}

- (void)rightMouseUp:(NSEvent *)event {
  [self recordCursor:event];
  if (!self.host)
    return;
  setMouseButton(self.host, MouseButton::right, false);
}

- (void)mouseMoved:(NSEvent *)event {
  [self recordCursor:event];
}

- (void)mouseDragged:(NSEvent *)event {
  [self recordCursor:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
  [self recordCursor:event];
}

- (void)scrollWheel:(NSEvent *)event {
  [self recordCursor:event];
  if (!self.host)
    return;
  self.host->scroll_delta += normalizedScrollDelta(event);
}

@end

@interface HeavySlugDemoWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@end

@implementation HeavySlugDemoWindowDelegate

- (BOOL)windowShouldClose:(id)sender {
  (void)sender;
  if (!self.host)
    return NO;
  self.host->should_close = true;
  clearInput(self.host);
  return NO;
}

- (void)windowDidResize:(NSNotification *)notification {
  (void)notification;
  updateDrawableSize(self.host);
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
  (void)notification;
  updateDrawableSize(self.host);
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
  (void)notification;
  updateDrawableSize(self.host);
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  clearInput(self.host);
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
  (void)notification;
  clearInput(self.host);
}

@end

static void ensureApp(void) {
  CocoaAppState &state = appState();
  [NSApplication sharedApplication];
  if (!state.delegate) {
    state.delegate = [[HeavySlugDemoAppDelegate alloc] init];
    NSApp.delegate = state.delegate;
  }
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  installMainMenu();
  if (!state.finished_launching) {
    [NSApp finishLaunching];
    state.finished_launching = true;
  }
}

hs_demo_cocoa_window *hs_demo_cocoa_window_create(int width, int height,
                                                  const char *title,
                                                  char *error_buffer,
                                                  size_t error_buffer_len) {
  @autoreleasepool {
    const ErrorSink error(errorBuffer(error_buffer, error_buffer_len));
    if (!requireMainThread(error))
      return nullptr;
    if (width <= 0 || height <= 0) {
      error.write(@"Cocoa demo host requires a positive initial window size");
      return nullptr;
    }

    ensureApp();

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      error.write(@"MTLCreateSystemDefaultDevice returned nil");
      return nullptr;
    }

    if (![device supportsFamily:MTLGPUFamilyMetal4]) {
      error.write(@"heavy-slug Metal demo requires a Metal 4 family GPU");
      return nullptr;
    }

    MTL4CommandQueueDescriptor *queue_desc = [MTL4CommandQueueDescriptor new];
    queue_desc.label = @"heavy-slug demo command queue";
    NSError *queue_error = nil;
    id<MTL4CommandQueue> command_queue =
        [device newMTL4CommandQueueWithDescriptor:queue_desc
                                            error:&queue_error];
    if (!command_queue) {
      error.write(@"failed to create Metal 4 command queue", queue_error);
      return nullptr;
    }

    auto host = std::make_unique<hs_demo_cocoa_window>(device, command_queue);

    NSRect rect = NSMakeRect(0, 0, static_cast<CGFloat>(width),
                             static_cast<CGFloat>(height));
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:rect
                                    styleMask:style
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    if (!window) {
      error.write(@"NSWindow init returned nil");
      return nullptr;
    }

    window.title = windowTitle(title);
    [window setReleasedWhenClosed:NO];
    window.tabbingMode = NSWindowTabbingModeDisallowed;

    CAMetalLayer *layer = [CAMetalLayer layer];
    if (!layer) {
      error.write(@"CAMetalLayer layer returned nil");
      return nullptr;
    }
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.displaySyncEnabled = YES;
    layer.presentsWithTransaction = NO;
    layer.opaque = YES;

    HeavySlugDemoView *view = [[HeavySlugDemoView alloc] initWithFrame:rect];
    if (!view) {
      error.write(@"HeavySlugDemoView init returned nil");
      return nullptr;
    }
    view.host = host.get();
    view.layer = layer;
    view.wantsLayer = YES;
    view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;

    HeavySlugDemoWindowDelegate *delegate =
        [[HeavySlugDemoWindowDelegate alloc] init];
    if (!delegate) {
      error.write(@"HeavySlugDemoWindowDelegate init returned nil");
      return nullptr;
    }
    delegate.host = host.get();

    host->window = window;
    host->view = view;
    host->delegate = delegate;
    host->layer = layer;
    appState().delegate.activeHost = host.get();

    window.contentView = view;
    window.delegate = delegate;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    updateDrawableSize(host.get());
    return host.release();
  }
}

void hs_demo_cocoa_window_destroy(hs_demo_cocoa_window *host) {
  if (!host)
    return;
  @autoreleasepool {
    std::unique_ptr<hs_demo_cocoa_window> owned(host);
    if (appState().delegate.activeHost == owned.get())
      appState().delegate.activeHost = nullptr;
    clearInput(owned.get());
    if (owned->view)
      owned->view.host = nullptr;
    if (owned->delegate)
      owned->delegate.host = nullptr;
    [owned->window orderOut:nil];
    owned->window.delegate = nil;
    owned->window.contentView = nil;
  }
}

void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host) {
  if (!host || ![NSThread isMainThread])
    return;
  @autoreleasepool {
    for (;;) {
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate distantPast]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (!event)
        break;
      [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    updateDrawableSize(host);
  }
}

void hs_demo_cocoa_window_snapshot(hs_demo_cocoa_window *host,
                                   hs_demo_cocoa_snapshot *snapshot) {
  if (!snapshot)
    return;
  if (!host) {
    *snapshot = hs_demo_cocoa_snapshot{};
    return;
  }
  copyBoolState(host->keys, snapshot->keys);
  copyBoolState(host->mouse_buttons, snapshot->mouse_buttons);
  snapshot->cursor_x = host->cursor_x;
  snapshot->cursor_y = host->cursor_y;
  snapshot->scroll_delta = host->scroll_delta;
  snapshot->framebuffer_width = host->framebuffer_width;
  snapshot->framebuffer_height = host->framebuffer_height;
  snapshot->should_close = host->should_close;
  host->scroll_delta = 0;
}

double hs_demo_cocoa_window_time(hs_demo_cocoa_window *host) {
  if (!host)
    return 0;
  return CACurrentMediaTime() - host->start_time;
}

void *hs_demo_cocoa_window_device(hs_demo_cocoa_window *host) {
  if (!host)
    return nullptr;
  return (__bridge void *)host->device;
}

void *hs_demo_cocoa_window_command_queue(hs_demo_cocoa_window *host) {
  if (!host)
    return nullptr;
  return (__bridge void *)host->command_queue;
}

void *hs_demo_cocoa_window_layer(hs_demo_cocoa_window *host) {
  if (!host)
    return nullptr;
  return (__bridge void *)host->layer;
}
