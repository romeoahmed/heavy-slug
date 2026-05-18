// Cocoa window and Metal demo host functions exposed to Zig.

#include "cocoa.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

@class HeavySlugDemoView;
@class HeavySlugDemoWindowDelegate;
@class HeavySlugDemoAppDelegate;

static NSString *const HeavySlugAppName = @"heavy-slug";
static NSString *const HeavySlugFallbackTitle = @"heavy-slug Metal 4 demo";
static constexpr double kPreciseScrollScale = 0.1;

static HeavySlugDemoAppDelegate *shared_app_delegate = nil;
static bool app_finished_launching = false;
static bool main_menu_installed = false;

struct hs_demo_cocoa_window {
    __strong NSWindow *window;
    __strong HeavySlugDemoView *view;
    __strong HeavySlugDemoWindowDelegate *delegate;
    __strong id<MTLDevice> device;
    __strong id<MTL4CommandQueue> command_queue;
    __strong CAMetalLayer *layer;
    bool keys[HS_DEMO_KEY_COUNT];
    bool mouse_buttons[HS_DEMO_MOUSE_COUNT];
    double cursor_x;
    double cursor_y;
    double scroll_delta;
    uint32_t framebuffer_width;
    uint32_t framebuffer_height;
    bool should_close;
    CFTimeInterval start_time;
};

@interface HeavySlugDemoAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *activeHost;
@end

static void write_error(char *buffer, size_t len, NSString *message) {
    if (buffer == nullptr || len == 0) return;
    const char *text = message ? [message UTF8String] : "unknown Cocoa host error";
    snprintf(buffer, len, "%s", text);
}

static bool require_main_thread(char *error_buffer, size_t error_buffer_len) {
    if ([NSThread isMainThread]) return true;
    write_error(error_buffer, error_buffer_len, @"Cocoa demo host must be created on the main thread");
    return false;
}

static void clear_input(hs_demo_cocoa_window *host) {
    if (!host) return;
    memset(host->keys, 0, sizeof(host->keys));
    memset(host->mouse_buttons, 0, sizeof(host->mouse_buttons));
    host->scroll_delta = 0;
}

static uint32_t pixel_dimension(CGFloat value) {
    if (!isfinite(value) || value <= 0) return 0;
    if (value >= (CGFloat)UINT32_MAX) return UINT32_MAX;
    return (uint32_t)llround(value);
}

static CGFloat contents_scale_for_bounds(NSRect logical_bounds, NSRect backing_bounds, NSWindow *window) {
    CGFloat scale_x = 0;
    CGFloat scale_y = 0;
    if (logical_bounds.size.width > 0) scale_x = backing_bounds.size.width / logical_bounds.size.width;
    if (logical_bounds.size.height > 0) scale_y = backing_bounds.size.height / logical_bounds.size.height;

    CGFloat scale = fmax(scale_x, scale_y);
    if (isfinite(scale) && scale > 0) return scale;

    if (window) {
        CGFloat fallback = window.backingScaleFactor;
        if (isfinite(fallback) && fallback > 0) return fallback;
    }
    return 1;
}

static void update_drawable_size(hs_demo_cocoa_window *host) {
    if (!host || !host->window || !host->view || !host->layer) return;
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
    uint32_t pixel_width = pixel_dimension(backing_bounds.size.width);
    uint32_t pixel_height = pixel_dimension(backing_bounds.size.height);
    host->layer.contentsScale = contents_scale_for_bounds(logical_bounds, backing_bounds, host->window);
    host->layer.drawableSize = CGSizeMake((CGFloat)pixel_width, (CGFloat)pixel_height);
    host->framebuffer_width = pixel_width;
    host->framebuffer_height = pixel_height;
}

static int key_index_for_character(unichar character) {
    switch (character) {
        case 0x1b: return HS_DEMO_KEY_ESCAPE;
        case ' ': return HS_DEMO_KEY_SPACE;
        case '=':
        case '+': return HS_DEMO_KEY_EQUAL;
        case '-':
        case '_': return HS_DEMO_KEY_MINUS;
        case 'b':
        case 'B': return HS_DEMO_KEY_B;
        case 'r':
        case 'R': return HS_DEMO_KEY_R;
        case NSUpArrowFunctionKey: return HS_DEMO_KEY_UP;
        case NSDownArrowFunctionKey: return HS_DEMO_KEY_DOWN;
        case NSLeftArrowFunctionKey: return HS_DEMO_KEY_LEFT;
        case NSRightArrowFunctionKey: return HS_DEMO_KEY_RIGHT;
        default: return -1;
    }
}

static int key_index_for_event(NSEvent *event) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 0) return -1;
    return key_index_for_character([characters characterAtIndex:0]);
}

static double normalized_scroll_delta(NSEvent *event) {
    double delta = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) return delta * kPreciseScrollScale;
    return delta;
}

static NSMenuItem *menu_item(NSString *title, SEL action, NSString *key, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = target;
    if (key.length > 0) item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    return item;
}

static void install_main_menu(void) {
    if (main_menu_installed) return;

    NSMenu *main_menu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *app_menu_item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *app_menu = [[NSMenu alloc] initWithTitle:HeavySlugAppName];
    [app_menu addItem:menu_item(@"About heavy-slug", @selector(orderFrontStandardAboutPanel:), @"", NSApp)];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItem:menu_item(@"Quit heavy-slug", @selector(terminate:), @"q", NSApp)];
    app_menu_item.submenu = app_menu;
    [main_menu addItem:app_menu_item];

    NSMenuItem *file_menu_item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *file_menu = [[NSMenu alloc] initWithTitle:@"File"];
    [file_menu addItem:menu_item(@"Close Window", @selector(performClose:), @"w", nil)];
    file_menu_item.submenu = file_menu;
    [main_menu addItem:file_menu_item];

    NSApp.mainMenu = main_menu;
    main_menu_installed = true;
}

@implementation HeavySlugDemoAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.activeHost) {
        self.activeHost->should_close = true;
        clear_input(self.activeHost);
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    clear_input(self.activeHost);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)flag;
    if (!self.activeHost || self.activeHost->should_close) return NO;
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
    if (_mouseTrackingArea) [self removeTrackingArea:_mouseTrackingArea];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self.window makeFirstResponder:self];
    [self updateTrackingAreas];
    update_drawable_size(self.host);
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    update_drawable_size(self.host);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    update_drawable_size(self.host);
}

- (void)setBoundsSize:(NSSize)newSize {
    [super setBoundsSize:newSize];
    update_drawable_size(self.host);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.mouseTrackingArea) {
        [self removeTrackingArea:self.mouseTrackingArea];
        self.mouseTrackingArea = nil;
    }

    NSTrackingAreaOptions options =
        NSTrackingMouseMoved |
        NSTrackingCursorUpdate |
        NSTrackingActiveInKeyWindow |
        NSTrackingInVisibleRect |
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
    if (!self.host) return;
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

    int index = key_index_for_event(event);
    if (index >= 0) {
        self.host->keys[index] = true;
        return;
    }
    [super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    if (!self.host) {
        [super keyUp:event];
        return;
    }
    int index = key_index_for_event(event);
    if (index >= 0) {
        self.host->keys[index] = false;
        return;
    }
    [super keyUp:event];
}

- (void)mouseDown:(NSEvent *)event {
    [self recordCursor:event];
    if (!self.host) return;
    self.host->mouse_buttons[HS_DEMO_MOUSE_LEFT] = true;
}

- (void)mouseUp:(NSEvent *)event {
    [self recordCursor:event];
    if (!self.host) return;
    self.host->mouse_buttons[HS_DEMO_MOUSE_LEFT] = false;
}

- (void)rightMouseDown:(NSEvent *)event {
    [self recordCursor:event];
    if (!self.host) return;
    self.host->mouse_buttons[HS_DEMO_MOUSE_RIGHT] = true;
}

- (void)rightMouseUp:(NSEvent *)event {
    [self recordCursor:event];
    if (!self.host) return;
    self.host->mouse_buttons[HS_DEMO_MOUSE_RIGHT] = false;
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
    if (!self.host) return;
    self.host->scroll_delta += normalized_scroll_delta(event);
}

@end

@interface HeavySlugDemoWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@end

@implementation HeavySlugDemoWindowDelegate

- (BOOL)windowShouldClose:(id)sender {
    (void)sender;
    self.host->should_close = true;
    clear_input(self.host);
    return NO;
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    update_drawable_size(self.host);
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    (void)notification;
    update_drawable_size(self.host);
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification;
    update_drawable_size(self.host);
}

- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification;
    clear_input(self.host);
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
    (void)notification;
    clear_input(self.host);
}

@end

static void ensure_app(void) {
    [NSApplication sharedApplication];
    if (!shared_app_delegate) {
        shared_app_delegate = [[HeavySlugDemoAppDelegate alloc] init];
        NSApp.delegate = shared_app_delegate;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    install_main_menu();
    if (!app_finished_launching) {
        [NSApp finishLaunching];
        app_finished_launching = true;
    }
}

hs_demo_cocoa_window *hs_demo_cocoa_window_create(
    int width,
    int height,
    const char *title,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        if (!require_main_thread(error_buffer, error_buffer_len)) return nullptr;
        if (width <= 0 || height <= 0) {
            write_error(error_buffer, error_buffer_len, @"Cocoa demo host requires a positive initial window size");
            return nullptr;
        }

        ensure_app();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            write_error(error_buffer, error_buffer_len, @"MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        if (![device supportsFamily:MTLGPUFamilyMetal4]) {
            write_error(error_buffer, error_buffer_len, @"heavy-slug Metal demo requires a Metal 4 family GPU");
            return nullptr;
        }

        MTL4CommandQueueDescriptor *queue_desc = [MTL4CommandQueueDescriptor new];
        queue_desc.label = @"heavy-slug demo command queue";
        NSError *queue_error = nil;
        id<MTL4CommandQueue> command_queue = [device newMTL4CommandQueueWithDescriptor:queue_desc
                                                                                  error:&queue_error];
        if (!command_queue) {
            write_error(error_buffer, error_buffer_len, queue_error.localizedDescription);
            return nullptr;
        }

        hs_demo_cocoa_window *host = new hs_demo_cocoa_window();
        host->device = device;
        host->command_queue = command_queue;
        host->start_time = CACurrentMediaTime();

        NSRect rect = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask style =
            NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable |
            NSWindowStyleMaskResizable;
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:rect
                      styleMask:style
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (!window) {
            write_error(error_buffer, error_buffer_len, @"NSWindow init returned nil");
            delete host;
            return nullptr;
        }

        NSString *title_string = title ? [NSString stringWithUTF8String:title] : HeavySlugFallbackTitle;
        window.title = title_string ?: HeavySlugFallbackTitle;
        [window setReleasedWhenClosed:NO];
        window.tabbingMode = NSWindowTabbingModeDisallowed;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = YES;
        layer.presentsWithTransaction = NO;
        layer.opaque = YES;

        HeavySlugDemoView *view = [[HeavySlugDemoView alloc] initWithFrame:rect];
        view.host = host;
        view.layer = layer;
        view.wantsLayer = YES;
        view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;

        HeavySlugDemoWindowDelegate *delegate = [[HeavySlugDemoWindowDelegate alloc] init];
        delegate.host = host;

        host->window = window;
        host->view = view;
        host->delegate = delegate;
        host->layer = layer;
        shared_app_delegate.activeHost = host;

        window.contentView = view;
        window.delegate = delegate;
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activate];
        update_drawable_size(host);
        return host;
    }
}

void hs_demo_cocoa_window_destroy(hs_demo_cocoa_window *host) {
    if (!host) return;
    @autoreleasepool {
        if (shared_app_delegate.activeHost == host) shared_app_delegate.activeHost = nullptr;
        clear_input(host);
        host->view.host = nullptr;
        host->delegate.host = nullptr;
        [host->window orderOut:nil];
        host->window.delegate = nil;
        host->window.contentView = nil;
        delete host;
    }
}

void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host) {
    if (!host || ![NSThread isMainThread]) return;
    @autoreleasepool {
        for (;;) {
            NSEvent *event = [NSApp
                nextEventMatchingMask:NSEventMaskAny
                            untilDate:[NSDate distantPast]
                               inMode:NSDefaultRunLoopMode
                              dequeue:YES];
            if (!event) break;
            [NSApp sendEvent:event];
        }
        [NSApp updateWindows];
        update_drawable_size(host);
    }
}

void hs_demo_cocoa_window_snapshot(hs_demo_cocoa_window *host, hs_demo_cocoa_snapshot *snapshot) {
    if (!snapshot) return;
    if (!host) {
        memset(snapshot, 0, sizeof(*snapshot));
        return;
    }
    for (int i = 0; i < HS_DEMO_KEY_COUNT; ++i) snapshot->keys[i] = host->keys[i];
    for (int i = 0; i < HS_DEMO_MOUSE_COUNT; ++i) snapshot->mouse_buttons[i] = host->mouse_buttons[i];
    snapshot->cursor_x = host->cursor_x;
    snapshot->cursor_y = host->cursor_y;
    snapshot->scroll_delta = host->scroll_delta;
    snapshot->framebuffer_width = host->framebuffer_width;
    snapshot->framebuffer_height = host->framebuffer_height;
    snapshot->should_close = host->should_close;
    host->scroll_delta = 0;
}

double hs_demo_cocoa_window_time(hs_demo_cocoa_window *host) {
    if (!host) return 0;
    return CACurrentMediaTime() - host->start_time;
}

void *hs_demo_cocoa_window_device(hs_demo_cocoa_window *host) {
    if (!host) return nullptr;
    return (__bridge void *)host->device;
}

void *hs_demo_cocoa_window_command_queue(hs_demo_cocoa_window *host) {
    if (!host) return nullptr;
    return (__bridge void *)host->command_queue;
}

void *hs_demo_cocoa_window_layer(hs_demo_cocoa_window *host) {
    if (!host) return nullptr;
    return (__bridge void *)host->layer;
}
