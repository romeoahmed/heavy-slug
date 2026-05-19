// Demo-only Cocoa host and Metal 4 object provider for the Zig demo.

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
#include <expected>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

@class HeavySlugDemoAppDelegate;
@class HeavySlugDemoView;
@class HeavySlugDemoWindowDelegate;

static NSString *const HeavySlugAppName = @"heavy-slug";
static NSString *const HeavySlugFallbackTitle = @"heavy-slug Metal 4 demo";

namespace {

using namespace std::string_view_literals;

constexpr double kPreciseScrollScale = 0.1;

using Utf8View = std::u8string_view;

struct Failure final {
  __strong NSString *message = nil;
};

template <typename T> using Result = std::expected<T, Failure>;
using Status = std::expected<void, Failure>;

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

[[nodiscard]] constexpr const char *charData(Utf8View text) noexcept {
  return reinterpret_cast<const char *>(text.data());
}

[[nodiscard]] constexpr Utf8View utf8View(const char *data,
                                          std::size_t length) noexcept {
  return {reinterpret_cast<const char8_t *>(data), length};
}

[[nodiscard]] NSString *makeNSString(Utf8View text) {
  if (text.empty()) {
    return @"";
  }
  return [[NSString alloc] initWithBytes:charData(text)
                                  length:text.size()
                                encoding:NSUTF8StringEncoding];
}

[[nodiscard]] std::unexpected<Failure> fail(NSString *message) {
  if (!message) {
    message = @"unknown Cocoa host error";
  }
  return std::unexpected<Failure>{Failure{message}};
}

[[nodiscard]] std::unexpected<Failure> fail(Utf8View message) {
  NSString *text = makeNSString(message);
  if (!text) {
    text = @"invalid UTF-8 diagnostic";
  }
  return fail(text);
}

[[nodiscard]] std::unexpected<Failure> fail(NSString *prefix, NSError *error) {
  if (error && error.localizedDescription.length > 0) {
    return fail([NSString stringWithFormat:@"%@: %@", prefix,
                                           error.localizedDescription]);
  }
  return fail(prefix);
}

class ErrorBuffer final {
public:
  explicit ErrorBuffer(hs_demo_cocoa_error_buffer buffer) noexcept
      : storage_(buffer.data && buffer.len > 0
                     ? std::span<char>{buffer.data, buffer.len}
                     : std::span<char>{}) {
    if (!storage_.empty()) {
      storage_.front() = '\0';
    }
  }

  void write(const Failure &failure) const {
    if (storage_.empty()) {
      return;
    }
    NSString *message = failure.message;
    if (!message) {
      message = @"unknown Cocoa host error";
    }
    const char *bytes = [message UTF8String];
    if (!bytes) {
      bytes = "unknown Cocoa host error";
    }
    std::snprintf(storage_.data(), storage_.size(), "%s", bytes);
  }

private:
  std::span<char> storage_;
};

template <typename T, typename... Args>
[[nodiscard]] std::unique_ptr<T> makeOwned(Args &&...args) {
  return std::unique_ptr<T>(
      new (std::nothrow) T(std::forward<Args>(args)...));
}

[[nodiscard]] bool isMainThread() { return [NSThread isMainThread]; }

[[nodiscard]] Status requireMainThread() {
  if (isMainThread()) {
    return {};
  }
  return fail(u8"Cocoa demo host must be used on the main thread"sv);
}

} // namespace

struct hs_demo_cocoa_window final {
  __strong NSWindow *window = nil;
  __strong HeavySlugDemoView *view = nil;
  __strong HeavySlugDemoWindowDelegate *delegate = nil;
  __strong id<MTLDevice> device = nil;
  __strong id<MTL4CommandQueue> commandQueue = nil;
  __strong CAMetalLayer *layer = nil;
  std::array<bool, HS_DEMO_KEY_COUNT> keys{};
  std::array<bool, HS_DEMO_MOUSE_COUNT> mouseButtons{};
  double cursorX = 0;
  double cursorY = 0;
  double scrollDelta = 0;
  std::uint32_t framebufferWidth = 0;
  std::uint32_t framebufferHeight = 0;
  bool shouldClose = false;
  CFTimeInterval startTime = 0;

  hs_demo_cocoa_window(id<MTLDevice> device_,
                       id<MTL4CommandQueue> command_queue) noexcept
      : device(device_), commandQueue(command_queue),
        startTime(CACurrentMediaTime()) {}

  hs_demo_cocoa_window(const hs_demo_cocoa_window &) = delete;
  hs_demo_cocoa_window &operator=(const hs_demo_cocoa_window &) = delete;

  void clearInput() noexcept {
    keys.fill(false);
    mouseButtons.fill(false);
    scrollDelta = 0;
  }
};

@interface HeavySlugDemoAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *activeHost;
@end

@interface HeavySlugDemoView : NSView
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
@end

@interface HeavySlugDemoWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@end

namespace {

struct CocoaAppState final {
  __strong HeavySlugDemoAppDelegate *delegate = nil;
  bool finishedLaunching = false;
  bool installedMenu = false;
};

[[nodiscard]] CocoaAppState &appState() noexcept {
  static CocoaAppState state;
  return state;
}

void clearInput(hs_demo_cocoa_window *host) {
  if (host) {
    host->clearInput();
  }
}

[[nodiscard]] std::uint32_t pixelDimension(CGFloat value) {
  if (!std::isfinite(value) || value <= 0) {
    return 0;
  }
  constexpr auto max_value =
      static_cast<CGFloat>(std::numeric_limits<std::uint32_t>::max());
  if (value >= max_value) {
    return std::numeric_limits<std::uint32_t>::max();
  }
  return static_cast<std::uint32_t>(std::llround(value));
}

[[nodiscard]] CGFloat contentsScale(NSRect logical_bounds,
                                    NSRect backing_bounds, NSWindow *window) {
  CGFloat scale_x = 0;
  CGFloat scale_y = 0;
  if (logical_bounds.size.width > 0) {
    scale_x = backing_bounds.size.width / logical_bounds.size.width;
  }
  if (logical_bounds.size.height > 0) {
    scale_y = backing_bounds.size.height / logical_bounds.size.height;
  }

  const CGFloat converted_scale = std::max(scale_x, scale_y);
  if (std::isfinite(converted_scale) && converted_scale > 0) {
    return converted_scale;
  }

  if (window) {
    const CGFloat window_scale = window.backingScaleFactor;
    if (std::isfinite(window_scale) && window_scale > 0) {
      return window_scale;
    }
  }
  return 1;
}

void updateDrawableSize(hs_demo_cocoa_window *host) {
  if (!host || !host->window || !host->view || !host->layer) {
    return;
  }

  NSView *view = (NSView *)host->view;
  const NSRect logical_bounds = view.bounds;
  host->layer.frame = logical_bounds;

  if (logical_bounds.size.width <= 0 || logical_bounds.size.height <= 0) {
    host->layer.drawableSize = CGSizeZero;
    host->framebufferWidth = 0;
    host->framebufferHeight = 0;
    return;
  }

  const NSRect backing_bounds = [view convertRectToBacking:logical_bounds];
  const std::uint32_t width = pixelDimension(backing_bounds.size.width);
  const std::uint32_t height = pixelDimension(backing_bounds.size.height);
  host->layer.contentsScale =
      contentsScale(logical_bounds, backing_bounds, host->window);
  host->layer.drawableSize =
      CGSizeMake(static_cast<CGFloat>(width), static_cast<CGFloat>(height));
  host->framebufferWidth = width;
  host->framebufferHeight = height;
}

void updateCursor(hs_demo_cocoa_window *host, NSView *view, NSPoint point) {
  if (!host || !view) {
    return;
  }

  const NSRect bounds = view.bounds;
  if (bounds.size.width <= 0 || bounds.size.height <= 0 ||
      host->framebufferWidth == 0 || host->framebufferHeight == 0) {
    host->cursorX = 0;
    host->cursorY = 0;
    return;
  }

  host->cursorX = point.x *
                  (static_cast<double>(host->framebufferWidth) /
                   static_cast<double>(bounds.size.width));
  host->cursorY = point.y *
                  (static_cast<double>(host->framebufferHeight) /
                   static_cast<double>(bounds.size.height));
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
  if (characters.length == 0) {
    return std::nullopt;
  }
  return keyForCharacter([characters characterAtIndex:0]);
}

void setKey(hs_demo_cocoa_window *host, DemoKey key, bool pressed) {
  host->keys[keyIndex(key)] = pressed;
}

void setMouseButton(hs_demo_cocoa_window *host, MouseButton button,
                    bool pressed) {
  host->mouseButtons[mouseIndex(button)] = pressed;
}

template <std::size_t Count>
void copyBoolState(const std::array<bool, Count> &source,
                   bool (&destination)[Count]) {
  for (std::size_t index = 0; index < Count; index += 1) {
    destination[index] = source[index];
  }
}

[[nodiscard]] Result<NSString *>
windowTitle(hs_demo_cocoa_utf8_span title) {
  if (title.data == nullptr && title.len != 0) {
    return fail(u8"Cocoa window title pointer is null"sv);
  }
  if (title.data == nullptr || title.len == 0) {
    return HeavySlugFallbackTitle;
  }

  NSString *string = makeNSString(utf8View(title.data, title.len));
  if (!string) {
    return fail(u8"Cocoa window title is not valid UTF-8"sv);
  }
  return string;
}

[[nodiscard]] double scrollDelta(NSEvent *event) {
  const double delta = event.scrollingDeltaY;
  return event.hasPreciseScrollingDeltas ? delta * kPreciseScrollScale : delta;
}

[[nodiscard]] Result<NSMenuItem *>
makeMenuItem(NSString *title, SEL action, NSString *key, id target) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:key];
  if (!item) {
    return fail(u8"NSMenuItem init returned nil"sv);
  }
  item.target = target;
  if (key.length > 0) {
    item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  }
  return item;
}

[[nodiscard]] Status installMainMenu() {
  CocoaAppState &state = appState();
  if (state.installedMenu) {
    return {};
  }

  NSMenu *main_menu = [[NSMenu alloc] initWithTitle:@""];
  if (!main_menu) {
    return fail(u8"NSMenu init returned nil"sv);
  }

  NSMenuItem *app_menu_item = [[NSMenuItem alloc] initWithTitle:@""
                                                         action:nil
                                                  keyEquivalent:@""];
  NSMenu *app_menu = [[NSMenu alloc] initWithTitle:HeavySlugAppName];
  if (!app_menu_item || !app_menu) {
    return fail(u8"failed to allocate Cocoa application menu"sv);
  }

  auto about_item =
      makeMenuItem(@"About heavy-slug", @selector(orderFrontStandardAboutPanel:),
                   @"", NSApp);
  if (!about_item) {
    return std::unexpected<Failure>{about_item.error()};
  }
  [app_menu addItem:*about_item];
  [app_menu addItem:[NSMenuItem separatorItem]];

  auto quit_item =
      makeMenuItem(@"Quit heavy-slug", @selector(terminate:), @"q", NSApp);
  if (!quit_item) {
    return std::unexpected<Failure>{quit_item.error()};
  }
  [app_menu addItem:*quit_item];
  app_menu_item.submenu = app_menu;
  [main_menu addItem:app_menu_item];

  NSMenuItem *file_menu_item = [[NSMenuItem alloc] initWithTitle:@""
                                                          action:nil
                                                   keyEquivalent:@""];
  NSMenu *file_menu = [[NSMenu alloc] initWithTitle:@"File"];
  if (!file_menu_item || !file_menu) {
    return fail(u8"failed to allocate Cocoa file menu"sv);
  }

  auto close_item =
      makeMenuItem(@"Close Window", @selector(performClose:), @"w", nil);
  if (!close_item) {
    return std::unexpected<Failure>{close_item.error()};
  }
  [file_menu addItem:*close_item];
  file_menu_item.submenu = file_menu;
  [main_menu addItem:file_menu_item];

  NSApp.mainMenu = main_menu;
  state.installedMenu = true;
  return {};
}

[[nodiscard]] Status ensureApplication() {
  CocoaAppState &state = appState();
  [NSApplication sharedApplication];
  if (!NSApp) {
    return fail(u8"NSApplication sharedApplication returned nil"sv);
  }

  if (!state.delegate) {
    state.delegate = [[HeavySlugDemoAppDelegate alloc] init];
    if (!state.delegate) {
      return fail(u8"HeavySlugDemoAppDelegate init returned nil"sv);
    }
    NSApp.delegate = state.delegate;
  }

  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  auto menu_status = installMainMenu();
  if (!menu_status) {
    return std::unexpected<Failure>{menu_status.error()};
  }

  if (!state.finishedLaunching) {
    [NSApp finishLaunching];
    state.finishedLaunching = true;
  }
  return {};
}

[[nodiscard]] Result<id<MTLDevice>> makeDevice() {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    return fail(u8"MTLCreateSystemDefaultDevice returned nil"sv);
  }
  if (![device supportsFamily:MTLGPUFamilyMetal4]) {
    return fail(u8"heavy-slug Metal demo requires a Metal 4 family GPU"sv);
  }
  return device;
}

[[nodiscard]] Result<id<MTL4CommandQueue>>
makeCommandQueue(id<MTLDevice> device) {
  MTL4CommandQueueDescriptor *descriptor = [MTL4CommandQueueDescriptor new];
  if (!descriptor) {
    return fail(u8"failed to allocate MTL4CommandQueueDescriptor"sv);
  }
  descriptor.label = @"heavy-slug demo command queue";

  NSError *queue_error = nil;
  id<MTL4CommandQueue> queue =
      [device newMTL4CommandQueueWithDescriptor:descriptor error:&queue_error];
  if (!queue) {
    return fail(@"failed to create Metal 4 command queue", queue_error);
  }
  return queue;
}

[[nodiscard]] Result<CAMetalLayer *> makeMetalLayer(id<MTLDevice> device) {
  CAMetalLayer *layer = [CAMetalLayer layer];
  if (!layer) {
    return fail(u8"CAMetalLayer layer returned nil"sv);
  }
  layer.device = device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  layer.displaySyncEnabled = YES;
  layer.presentsWithTransaction = NO;
  layer.allowsNextDrawableTimeout = YES;
  layer.opaque = YES;
  if (!layer.residencySet) {
    return fail(u8"CAMetalLayer did not expose a Metal 4 residency set"sv);
  }
  return layer;
}

[[nodiscard]] Result<NSWindow *> makeWindow(NSRect rect, NSString *title) {
  const NSWindowStyleMask style =
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
  NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                 styleMask:style
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  if (!window) {
    return fail(u8"NSWindow init returned nil"sv);
  }
  window.title = title;
  [window setReleasedWhenClosed:NO];
  window.tabbingMode = NSWindowTabbingModeDisallowed;
  return window;
}

[[nodiscard]] Result<std::unique_ptr<hs_demo_cocoa_window>>
makeCocoaWindow(std::uint32_t width, std::uint32_t height,
                hs_demo_cocoa_utf8_span title) {
  auto thread_status = requireMainThread();
  if (!thread_status) {
    return std::unexpected<Failure>{thread_status.error()};
  }
  if (width == 0 || height == 0) {
    return fail(u8"Cocoa demo host requires a positive initial window size"sv);
  }

  auto title_string = windowTitle(title);
  if (!title_string) {
    return std::unexpected<Failure>{title_string.error()};
  }

  auto app_status = ensureApplication();
  if (!app_status) {
    return std::unexpected<Failure>{app_status.error()};
  }

  auto device = makeDevice();
  if (!device) {
    return std::unexpected<Failure>{device.error()};
  }

  auto command_queue = makeCommandQueue(*device);
  if (!command_queue) {
    return std::unexpected<Failure>{command_queue.error()};
  }

  auto host = makeOwned<hs_demo_cocoa_window>(*device, *command_queue);
  if (!host) {
    return fail(u8"failed to allocate Cocoa demo host"sv);
  }

  const NSRect rect = NSMakeRect(0, 0, static_cast<CGFloat>(width),
                                static_cast<CGFloat>(height));
  auto window = makeWindow(rect, *title_string);
  if (!window) {
    return std::unexpected<Failure>{window.error()};
  }

  auto layer = makeMetalLayer(*device);
  if (!layer) {
    return std::unexpected<Failure>{layer.error()};
  }

  HeavySlugDemoView *view = [[HeavySlugDemoView alloc] initWithFrame:rect];
  if (!view) {
    return fail(u8"HeavySlugDemoView init returned nil"sv);
  }
  view.host = host.get();
  view.wantsLayer = YES;
  view.layer = *layer;
  view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;

  HeavySlugDemoWindowDelegate *delegate =
      [[HeavySlugDemoWindowDelegate alloc] init];
  if (!delegate) {
    return fail(u8"HeavySlugDemoWindowDelegate init returned nil"sv);
  }
  delegate.host = host.get();

  host->window = *window;
  host->view = view;
  host->delegate = delegate;
  host->layer = *layer;
  appState().delegate.activeHost = host.get();

  (*window).contentView = view;
  (*window).delegate = delegate;
  [*window center];
  [*window makeKeyAndOrderFront:nil];
  [NSApp activate];
  updateDrawableSize(host.get());
  return std::move(host);
}

} // namespace

@implementation HeavySlugDemoAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication *)sender {
  (void)sender;
  if (!self.activeHost) {
    return NSTerminateNow;
  }
  self.activeHost->shouldClose = true;
  clearInput(self.activeHost);
  return NSTerminateCancel;
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
  if (!self.activeHost || self.activeHost->shouldClose) {
    return NO;
  }
  [self.activeHost->window deminiaturize:nil];
  [self.activeHost->window makeKeyAndOrderFront:nil];
  [sender activate];
  return YES;
}

@end

@implementation HeavySlugDemoView

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)dealloc {
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    [self.window makeFirstResponder:self];
  }
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
  if (self.trackingArea) {
    [self removeTrackingArea:self.trackingArea];
    self.trackingArea = nil;
  }

  const NSTrackingAreaOptions options =
      NSTrackingMouseMoved | NSTrackingCursorUpdate |
      NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
      NSTrackingEnabledDuringMouseDrag;
  NSTrackingArea *tracking_area =
      [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                   options:options
                                     owner:self
                                  userInfo:nil];
  if (!tracking_area) {
    return;
  }
  self.trackingArea = tracking_area;
  [self addTrackingArea:tracking_area];
}

- (void)cursorUpdate:(NSEvent *)event {
  (void)event;
  [[NSCursor arrowCursor] set];
}

- (void)recordCursor:(NSEvent *)event {
  if (!self.host) {
    return;
  }
  const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  updateCursor(self.host, self, point);
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

  const std::optional<DemoKey> key = keyForEvent(event);
  if (!key) {
    [super keyDown:event];
    return;
  }
  setKey(self.host, *key, true);
}

- (void)keyUp:(NSEvent *)event {
  if (!self.host) {
    [super keyUp:event];
    return;
  }
  const std::optional<DemoKey> key = keyForEvent(event);
  if (!key) {
    [super keyUp:event];
    return;
  }
  setKey(self.host, *key, false);
}

- (void)mouseDown:(NSEvent *)event {
  [self recordCursor:event];
  if (self.host) {
    setMouseButton(self.host, MouseButton::left, true);
  }
}

- (void)mouseUp:(NSEvent *)event {
  [self recordCursor:event];
  if (self.host) {
    setMouseButton(self.host, MouseButton::left, false);
  }
}

- (void)rightMouseDown:(NSEvent *)event {
  [self recordCursor:event];
  if (self.host) {
    setMouseButton(self.host, MouseButton::right, true);
  }
}

- (void)rightMouseUp:(NSEvent *)event {
  [self recordCursor:event];
  if (self.host) {
    setMouseButton(self.host, MouseButton::right, false);
  }
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
  if (self.host) {
    self.host->scrollDelta += scrollDelta(event);
  }
}

@end

@implementation HeavySlugDemoWindowDelegate

- (BOOL)windowShouldClose:(id)sender {
  (void)sender;
  if (!self.host) {
    return NO;
  }
  self.host->shouldClose = true;
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

hs_demo_cocoa_window *
hs_demo_cocoa_window_create(uint32_t width, uint32_t height,
                            hs_demo_cocoa_utf8_span title,
                            hs_demo_cocoa_error_buffer error_buffer) {
  @autoreleasepool {
    ErrorBuffer error(error_buffer);
    auto host = makeCocoaWindow(width, height, title);
    if (!host) {
      error.write(host.error());
      return nullptr;
    }
    return host->release();
  }
}

void hs_demo_cocoa_window_destroy(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return;
  }

  @autoreleasepool {
    std::unique_ptr<hs_demo_cocoa_window> owned(host);
    if (appState().delegate.activeHost == owned.get()) {
      appState().delegate.activeHost = nullptr;
    }
    owned->clearInput();
    if (owned->view) {
      owned->view.host = nullptr;
    }
    if (owned->delegate) {
      owned->delegate.host = nullptr;
    }
    [owned->window orderOut:nil];
    owned->window.delegate = nil;
    owned->window.contentView = nil;
  }
}

void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return;
  }

  @autoreleasepool {
    for (;;) {
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate distantPast]
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (!event) {
        break;
      }
      [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    updateDrawableSize(host);
  }
}

void hs_demo_cocoa_window_snapshot(hs_demo_cocoa_window *host,
                                   hs_demo_cocoa_snapshot *snapshot) {
  if (!snapshot) {
    return;
  }
  if (!host || !isMainThread()) {
    *snapshot = hs_demo_cocoa_snapshot{};
    return;
  }

  copyBoolState(host->keys, snapshot->keys);
  copyBoolState(host->mouseButtons, snapshot->mouse_buttons);
  snapshot->cursor_x = host->cursorX;
  snapshot->cursor_y = host->cursorY;
  snapshot->scroll_delta = host->scrollDelta;
  snapshot->framebuffer_width = host->framebufferWidth;
  snapshot->framebuffer_height = host->framebufferHeight;
  snapshot->should_close = host->shouldClose;
  host->scrollDelta = 0;
}

double hs_demo_cocoa_window_time(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return 0;
  }
  return CACurrentMediaTime() - host->startTime;
}

void *hs_demo_cocoa_window_device(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return nullptr;
  }
  return (__bridge void *)host->device;
}

void *hs_demo_cocoa_window_command_queue(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return nullptr;
  }
  return (__bridge void *)host->commandQueue;
}

void *hs_demo_cocoa_window_layer(hs_demo_cocoa_window *host) {
  if (!host || !isMainThread()) {
    return nullptr;
  }
  return (__bridge void *)host->layer;
}
