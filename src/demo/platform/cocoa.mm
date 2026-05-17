// Cocoa window and Metal demo host functions exposed to Zig.

#include "cocoa.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <stdio.h>

@class HeavySlugDemoView;
@class HeavySlugDemoWindowDelegate;
@class HeavySlugDemoAppDelegate;

static NSString *const HeavySlugAppName = @"heavy-slug";

static HeavySlugDemoAppDelegate *shared_app_delegate = nil;

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

static void update_drawable_size(hs_demo_cocoa_window *host) {
    if (!host || !host->window || !host->view || !host->layer) return;
    CGFloat scale = host->window.backingScaleFactor;
    NSView *view = (NSView *)host->view;
    NSSize size = view.bounds.size;
    host->layer.contentsScale = scale;
    host->layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    host->framebuffer_width = (uint32_t)llround(size.width * scale);
    host->framebuffer_height = (uint32_t)llround(size.height * scale);
}

static int key_index(unsigned short key_code) {
    switch (key_code) {
        case 53: return HS_DEMO_KEY_ESCAPE;
        case 49: return HS_DEMO_KEY_SPACE;
        case 24: return HS_DEMO_KEY_EQUAL;
        case 27: return HS_DEMO_KEY_MINUS;
        case 11: return HS_DEMO_KEY_B;
        case 15: return HS_DEMO_KEY_R;
        case 126: return HS_DEMO_KEY_UP;
        case 125: return HS_DEMO_KEY_DOWN;
        case 123: return HS_DEMO_KEY_LEFT;
        case 124: return HS_DEMO_KEY_RIGHT;
        default: return -1;
    }
}

static NSMenuItem *menu_item(NSString *title, SEL action, NSString *key, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = target;
    if (key.length > 0) item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    return item;
}

static void install_main_menu(void) {
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
}

@implementation HeavySlugDemoAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.activeHost) {
        self.activeHost->should_close = true;
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

@end

@interface HeavySlugDemoView : NSView
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@end

@implementation HeavySlugDemoView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
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

- (void)recordCursor:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.host->cursor_x = point.x;
    self.host->cursor_y = point.y;
}

- (void)keyDown:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
        [super keyDown:event];
        return;
    }

    int index = key_index(event.keyCode);
    if (index >= 0) {
        self.host->keys[index] = true;
        return;
    }
    [super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    int index = key_index(event.keyCode);
    if (index >= 0) {
        self.host->keys[index] = false;
        return;
    }
    [super keyUp:event];
}

- (void)mouseDown:(NSEvent *)event {
    [self recordCursor:event];
    self.host->mouse_buttons[HS_DEMO_MOUSE_LEFT] = true;
}

- (void)mouseUp:(NSEvent *)event {
    [self recordCursor:event];
    self.host->mouse_buttons[HS_DEMO_MOUSE_LEFT] = false;
}

- (void)rightMouseDown:(NSEvent *)event {
    [self recordCursor:event];
    self.host->mouse_buttons[HS_DEMO_MOUSE_RIGHT] = true;
}

- (void)rightMouseUp:(NSEvent *)event {
    [self recordCursor:event];
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
    double delta = event.scrollingDeltaY;
    if (event.hasPreciseScrollingDeltas) delta /= 10.0;
    self.host->scroll_delta += delta;
}

@end

@interface HeavySlugDemoWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) hs_demo_cocoa_window *host;
@end

@implementation HeavySlugDemoWindowDelegate

- (BOOL)windowShouldClose:(id)sender {
    (void)sender;
    self.host->should_close = true;
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

@end

static void ensure_app(void) {
    [NSApplication sharedApplication];
    if (!shared_app_delegate) {
        shared_app_delegate = [[HeavySlugDemoAppDelegate alloc] init];
        NSApp.delegate = shared_app_delegate;
    }
    install_main_menu();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
}

hs_demo_cocoa_window *hs_demo_cocoa_window_create(
    int width,
    int height,
    const char *title,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        ensure_app();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            write_error(error_buffer, error_buffer_len, @"MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        id<MTL4CommandQueue> command_queue = [device newMTL4CommandQueue];
        if (!command_queue) {
            write_error(error_buffer, error_buffer_len, @"newMTL4CommandQueue returned nil");
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

        NSString *title_string = title ? [NSString stringWithUTF8String:title] : @"heavy-slug";
        window.title = title_string ?: @"heavy-slug";
        window.acceptsMouseMovedEvents = YES;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = YES;

        HeavySlugDemoView *view = [[HeavySlugDemoView alloc] initWithFrame:rect];
        view.host = host;
        view.wantsLayer = YES;
        view.layer = layer;

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
        [host->window orderOut:nil];
        host->window.delegate = nil;
        delete host;
    }
}

void hs_demo_cocoa_window_poll_events(hs_demo_cocoa_window *host) {
    if (!host) return;
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
    if (!host || !snapshot) return;
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
    return CACurrentMediaTime() - host->start_time;
}

void *hs_demo_cocoa_window_device(hs_demo_cocoa_window *host) {
    return (__bridge void *)host->device;
}

void *hs_demo_cocoa_window_command_queue(hs_demo_cocoa_window *host) {
    return (__bridge void *)host->command_queue;
}

void *hs_demo_cocoa_window_layer(hs_demo_cocoa_window *host) {
    return (__bridge void *)host->layer;
}
