#include "host.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#include <stdio.h>

struct hs_demo_metal_host {
    __strong id<MTLDevice> device;
    __strong id<MTLCommandQueue> command_queue;
    __strong CAMetalLayer *layer;
};

static void write_error(char *buffer, size_t len, NSString *message) {
    if (buffer == nullptr || len == 0) return;
    const char *text = message ? [message UTF8String] : "unknown Metal host error";
    snprintf(buffer, len, "%s", text);
}

hs_demo_metal_host *hs_demo_metal_host_create(
    GLFWwindow *window,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        NSWindow *ns_window = glfwGetCocoaWindow(window);
        if (!ns_window) {
            write_error(error_buffer, error_buffer_len, @"glfwGetCocoaWindow returned nil");
            return nullptr;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            write_error(error_buffer, error_buffer_len, @"MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        id<MTLCommandQueue> command_queue = [device newCommandQueue];
        if (!command_queue) {
            write_error(error_buffer, error_buffer_len, @"newCommandQueue returned nil");
            return nullptr;
        }

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = YES;

        NSView *view = [ns_window contentView];
        view.wantsLayer = YES;
        view.layer = layer;

        hs_demo_metal_host *host = new hs_demo_metal_host();
        host->device = device;
        host->command_queue = command_queue;
        host->layer = layer;
        return host;
    }
}

void hs_demo_metal_host_destroy(hs_demo_metal_host *host) {
    delete host;
}

void *hs_demo_metal_host_device(hs_demo_metal_host *host) {
    return (__bridge void *)host->device;
}

void *hs_demo_metal_host_command_queue(hs_demo_metal_host *host) {
    return (__bridge void *)host->command_queue;
}

void *hs_demo_metal_host_layer(hs_demo_metal_host *host) {
    return (__bridge void *)host->layer;
}
