#include "bridge.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

static constexpr uint32_t kFrameSlotCount = 3;

struct hs_metal_frame_slot {
    dispatch_semaphore_t semaphore;
    bool reserved;
    bool in_flight;
    bool failed;
    __strong NSString *message;
};

struct hs_metal_context {
    __unsafe_unretained id<MTLDevice> device;
    __unsafe_unretained id<MTLCommandQueue> command_queue;
    __strong id<MTLRenderPipelineState> pipeline_state;
    __unsafe_unretained CAMetalLayer *layer;
    hs_metal_frame_slot frame_slots[kFrameSlotCount];
};

struct hs_metal_buffer {
    __strong id<MTLBuffer> buffer;
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

hs_metal_context *hs_metal_context_create(
    hs_metal_host_objects host,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)host.device;
        if (!device) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil MTLDevice");
            return nullptr;
        }

        if (![device supportsFamily:MTLGPUFamilyMetal3]) {
            write_error(error_buffer, error_buffer_len, @"Metal mesh shaders require a Metal 3 family GPU or newer");
            return nullptr;
        }

        id<MTLCommandQueue> command_queue = (__bridge id<MTLCommandQueue>)host.command_queue;
        if (!command_queue) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil MTLCommandQueue");
            return nullptr;
        }

        CAMetalLayer *layer = (__bridge CAMetalLayer *)host.layer;
        if (!layer) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil CAMetalLayer");
            return nullptr;
        }

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
        pipeline_desc.colorAttachments[0].blendingEnabled = YES;
        pipeline_desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipeline_desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipeline_desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pipeline_desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipeline_desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipeline_desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

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
        context->command_queue = command_queue;
        context->pipeline_state = pipeline_state;
        context->layer = layer;
        for (uint32_t i = 0; i < kFrameSlotCount; i++) {
            context->frame_slots[i].semaphore = dispatch_semaphore_create(1);
            context->frame_slots[i].reserved = false;
            context->frame_slots[i].in_flight = false;
            context->frame_slots[i].failed = false;
            context->frame_slots[i].message = nil;
        }
        return context;
    }
}

static bool valid_slot(uint32_t slot_index) {
    return slot_index < kFrameSlotCount;
}

int hs_metal_context_wait_frame_slot(
    hs_metal_context *context,
    uint32_t slot_index,
    char *error_buffer,
    size_t error_buffer_len) {
    if (!context || !valid_slot(slot_index)) {
        write_error(error_buffer, error_buffer_len, @"invalid Metal frame slot");
        return 0;
    }

    hs_metal_frame_slot *slot = &context->frame_slots[slot_index];
    dispatch_semaphore_wait(slot->semaphore, DISPATCH_TIME_FOREVER);
    if (slot->failed) {
        write_error(error_buffer, error_buffer_len, slot->message);
        slot->failed = false;
        slot->message = nil;
        dispatch_semaphore_signal(slot->semaphore);
        return 0;
    }

    slot->reserved = true;
    return 1;
}

void hs_metal_context_release_frame_slot(hs_metal_context *context, uint32_t slot_index) {
    if (!context || !valid_slot(slot_index)) return;
    hs_metal_frame_slot *slot = &context->frame_slots[slot_index];
    if (!slot->reserved) return;
    slot->reserved = false;
    dispatch_semaphore_signal(slot->semaphore);
}

void hs_metal_context_wait_submitted(hs_metal_context *context) {
    if (!context) return;
    for (uint32_t i = 0; i < kFrameSlotCount; i++) {
        hs_metal_frame_slot *slot = &context->frame_slots[i];
        if (!slot->in_flight) continue;
        dispatch_semaphore_wait(slot->semaphore, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_signal(slot->semaphore);
    }
}

void hs_metal_context_destroy(hs_metal_context *context) {
    hs_metal_context_wait_submitted(context);
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
    uint32_t slot_index,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        if (!context || !commands || !push_constants || !glyph_pool) {
            write_error(error_buffer, error_buffer_len, @"Metal draw received a null handle");
            return 0;
        }
        if (!valid_slot(slot_index)) {
            write_error(error_buffer, error_buffer_len, @"invalid Metal frame slot");
            return 0;
        }
        hs_metal_frame_slot *slot = &context->frame_slots[slot_index];
        if (!slot->reserved) {
            write_error(error_buffer, error_buffer_len, @"Metal draw used an unreserved frame slot");
            return 0;
        }
        if (workgroup_count == 0) {
            hs_metal_context_release_frame_slot(context, slot_index);
            return 1;
        }

        context->layer.drawableSize = CGSizeMake(width, height);
        id<CAMetalDrawable> drawable = [context->layer nextDrawable];
        if (!drawable) {
            write_error(error_buffer, error_buffer_len, @"CAMetalLayer nextDrawable returned nil");
            hs_metal_context_release_frame_slot(context, slot_index);
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
        slot->reserved = false;
        slot->in_flight = true;
        slot->failed = false;
        slot->message = nil;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> command_buffer) {
            if ([command_buffer status] == MTLCommandBufferStatusError) {
                slot->failed = true;
                slot->message = command_buffer.error.localizedDescription;
            }
            slot->in_flight = false;
            dispatch_semaphore_signal(slot->semaphore);
        }];
        [cb commit];
        return 1;
    }
}
