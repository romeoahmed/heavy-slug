#include "bridge.h"

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#include <stdio.h>
#include <string.h>

struct hs_metal_context {
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<MTLRenderPipelineState> pipeline_state;
    CAMetalLayer *layer;
};

struct hs_metal_buffer {
    id<MTLBuffer> buffer;
};

static void write_error(char *buffer, size_t len, NSString *message) {
    if (buffer == nullptr || len == 0) return;
    const char *text = message ? [message UTF8String] : "unknown Metal error";
    snprintf(buffer, len, "%s", text);
}

static id<MTLLibrary> make_library(
    id<MTLDevice> device,
    const char *source,
    size_t source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    NSString *source_string = [[NSString alloc]
        initWithBytes:source
               length:source_len
             encoding:NSUTF8StringEncoding];
    if (!source_string) {
        write_error(error_buffer, error_buffer_len, @"failed to create NSString for Metal source");
        return nil;
    }

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source_string options:nil error:&error];
    if (!library) {
        write_error(error_buffer, error_buffer_len, error.localizedDescription);
        return nil;
    }
    return library;
}

static hs_metal_context *create_context(
    NSWindow *ns_window,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            write_error(error_buffer, error_buffer_len, @"MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        if (![device supportsFamily:MTLGPUFamilyMetal3]) {
            write_error(error_buffer, error_buffer_len, @"Metal mesh shaders require a Metal 3 family GPU or newer");
            return nullptr;
        }

        if (!ns_window) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil NSWindow");
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

        id<MTLLibrary> task_library = make_library(device, task_source, task_source_len, error_buffer, error_buffer_len);
        if (!task_library) return nullptr;
        id<MTLLibrary> mesh_library = make_library(device, mesh_source, mesh_source_len, error_buffer, error_buffer_len);
        if (!mesh_library) return nullptr;
        id<MTLLibrary> fragment_library = make_library(device, fragment_source, fragment_source_len, error_buffer, error_buffer_len);
        if (!fragment_library) return nullptr;

        id<MTLFunction> task_function = [task_library newFunctionWithName:@"taskMain"];
        id<MTLFunction> mesh_function = [mesh_library newFunctionWithName:@"meshMain"];
        id<MTLFunction> fragment_function = [fragment_library newFunctionWithName:@"fragmentMain"];
        if (!task_function || !mesh_function || !fragment_function) {
            write_error(error_buffer, error_buffer_len, @"failed to resolve taskMain, meshMain, or fragmentMain");
            return nullptr;
        }

        MTLMeshRenderPipelineDescriptor *pipeline_desc = [MTLMeshRenderPipelineDescriptor new];
        pipeline_desc.objectFunction = task_function;
        pipeline_desc.meshFunction = mesh_function;
        pipeline_desc.fragmentFunction = fragment_function;
        pipeline_desc.colorAttachments[0].pixelFormat = layer.pixelFormat;

        NSError *pipeline_error = nil;
        id<MTLRenderPipelineState> pipeline_state =
            [device newRenderPipelineStateWithMeshDescriptor:pipeline_desc
                                                     options:0
                                                  reflection:nil
                                                       error:&pipeline_error];
        if (!pipeline_state) {
            write_error(error_buffer, error_buffer_len, pipeline_error.localizedDescription);
            return nullptr;
        }

        hs_metal_context *context = new hs_metal_context();
        context->device = device;
        context->command_queue = [device newCommandQueue];
        context->pipeline_state = pipeline_state;
        context->layer = layer;
        return context;
    }
}

hs_metal_context *hs_metal_context_create_from_cocoa_window(
    void *ns_window,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    return create_context(
        (__bridge NSWindow *)ns_window,
        task_source,
        task_source_len,
        mesh_source,
        mesh_source_len,
        fragment_source,
        fragment_source_len,
        error_buffer,
        error_buffer_len);
}

hs_metal_context *hs_metal_context_create_from_glfw_window(
    GLFWwindow *window,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    NSWindow *ns_window = glfwGetCocoaWindow(window);
    if (!ns_window) {
        write_error(error_buffer, error_buffer_len, @"glfwGetCocoaWindow returned nil");
        return nullptr;
    }
    return create_context(
        ns_window,
        task_source,
        task_source_len,
        mesh_source,
        mesh_source_len,
        fragment_source,
        fragment_source_len,
        error_buffer,
        error_buffer_len);
}

void hs_metal_context_destroy(hs_metal_context *context) {
    delete context;
}

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context, size_t size) {
    if (!context) return nullptr;
    @autoreleasepool {
        id<MTLBuffer> buffer = [context->device newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (!buffer) return nullptr;
        hs_metal_buffer *result = new hs_metal_buffer();
        result->buffer = buffer;
        return result;
    }
}

void hs_metal_buffer_destroy(hs_metal_buffer *buffer) {
    delete buffer;
}

void *hs_metal_buffer_contents(hs_metal_buffer *buffer) {
    if (!buffer) return nullptr;
    return [buffer->buffer contents];
}

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
    size_t error_buffer_len) {
    @autoreleasepool {
        if (!context || !commands || !push_constants || !glyph_pool) {
            write_error(error_buffer, error_buffer_len, @"Metal draw received a null handle");
            return 0;
        }
        if (workgroup_count == 0) return 1;

        context->layer.drawableSize = CGSizeMake(width, height);
        id<CAMetalDrawable> drawable = [context->layer nextDrawable];
        if (!drawable) {
            write_error(error_buffer, error_buffer_len, @"CAMetalLayer nextDrawable returned nil");
            return 0;
        }

        MTLRenderPassDescriptor *pass_desc = [MTLRenderPassDescriptor renderPassDescriptor];
        pass_desc.colorAttachments[0].texture = drawable.texture;
        pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass_desc.colorAttachments[0].clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);

        id<MTLCommandBuffer> cb = [context->command_queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass_desc];
        [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        [encoder setRenderPipelineState:context->pipeline_state];
        [encoder setObjectBuffer:commands->buffer offset:0 atIndex:0];
        [encoder setObjectBuffer:push_constants->buffer offset:0 atIndex:1];
        [encoder setMeshBuffer:commands->buffer offset:0 atIndex:0];
        [encoder setMeshBuffer:push_constants->buffer offset:0 atIndex:1];
        [encoder setFragmentBuffer:glyph_pool->buffer offset:0 atIndex:0];
        [encoder drawMeshThreadgroups:MTLSizeMake(workgroup_count, 1, 1)
            threadsPerObjectThreadgroup:MTLSizeMake(32, 1, 1)
              threadsPerMeshThreadgroup:MTLSizeMake(4, 1, 1)];
        [encoder endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];
        [cb waitUntilCompleted];
        if ([cb status] == MTLCommandBufferStatusError) {
            write_error(error_buffer, error_buffer_len, cb.error.localizedDescription);
            return 0;
        }
        return 1;
    }
}
