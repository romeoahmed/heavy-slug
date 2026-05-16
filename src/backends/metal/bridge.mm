// Objective-C++ bridge for the Metal renderer ABI exposed to Zig.

#include "bridge.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

static constexpr uint32_t kFrameSlotCount = 3;
static constexpr uint32_t kArgumentBufferBindCount = HEAVY_SLUG_SHADER_STATS ? 4 : 3;

struct hs_metal_frame_slot {
    dispatch_semaphore_t semaphore;
    __strong id<MTL4CommandAllocator> allocator;
    __strong id<MTL4ArgumentTable> argument_table;
    bool reserved;
    bool in_flight;
    bool failed;
    __strong NSString *message;
};

struct hs_metal_context {
    __unsafe_unretained id<MTLDevice> device;
    __unsafe_unretained id<MTL4CommandQueue> command_queue;
    __strong id<MTL4Compiler> compiler;
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
    id<MTL4Compiler> compiler,
    const char *source,
    size_t source_len,
    NSString *name,
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

    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion4_0;

    MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
    descriptor.source = source_string;
    descriptor.options = options;
    descriptor.name = name;

    NSError *error = nil;
    id<MTLLibrary> library = [compiler newLibraryWithDescriptor:descriptor error:&error];
    if (!library) {
        write_error(error_buffer, error_buffer_len, error.localizedDescription);
        return nil;
    }
    return library;
}

static MTL4LibraryFunctionDescriptor *function_descriptor(id<MTLLibrary> library, NSString *name) {
    MTL4LibraryFunctionDescriptor *descriptor = [MTL4LibraryFunctionDescriptor new];
    descriptor.library = library;
    descriptor.name = name;
    return descriptor;
}

static id<MTL4ArgumentTable> make_argument_table(
    id<MTLDevice> device,
    NSString *label,
    char *error_buffer,
    size_t error_buffer_len) {
    MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
    descriptor.maxBufferBindCount = kArgumentBufferBindCount;
    descriptor.maxTextureBindCount = 0;
    descriptor.maxSamplerStateBindCount = 0;
    descriptor.initializeBindings = YES;
    descriptor.label = label;

    NSError *error = nil;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:descriptor error:&error];
    if (!table) {
        write_error(error_buffer, error_buffer_len, error.localizedDescription);
        return nil;
    }
    return table;
}

static void bind_buffer(id<MTL4ArgumentTable> table, hs_metal_buffer *buffer, NSUInteger index) {
    [table setAddress:buffer->buffer.gpuAddress atIndex:index];
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

        if (![device supportsFamily:MTLGPUFamilyMetal4]) {
            write_error(error_buffer, error_buffer_len, @"heavy-slug metal4 requires a Metal 4 family GPU");
            return nullptr;
        }

        id<MTL4CommandQueue> command_queue = (__bridge id<MTL4CommandQueue>)host.command_queue;
        if (!command_queue) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil MTL4CommandQueue");
            return nullptr;
        }

        CAMetalLayer *layer = (__bridge CAMetalLayer *)host.layer;
        if (!layer) {
            write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil CAMetalLayer");
            return nullptr;
        }

        NSError *compiler_error = nil;
        MTL4CompilerDescriptor *compiler_desc = [MTL4CompilerDescriptor new];
        compiler_desc.label = @"heavy-slug compiler";
        id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:compiler_desc error:&compiler_error];
        if (!compiler) {
            write_error(error_buffer, error_buffer_len, compiler_error.localizedDescription);
            return nullptr;
        }

        id<MTLLibrary> task_library = make_library(compiler, task_source, task_source_len, @"heavy-slug task", error_buffer, error_buffer_len);
        if (!task_library) return nullptr;
        id<MTLLibrary> mesh_library = make_library(compiler, mesh_source, mesh_source_len, @"heavy-slug mesh", error_buffer, error_buffer_len);
        if (!mesh_library) return nullptr;
        id<MTLLibrary> fragment_library = make_library(compiler, fragment_source, fragment_source_len, @"heavy-slug fragment", error_buffer, error_buffer_len);
        if (!fragment_library) return nullptr;

        MTL4MeshRenderPipelineDescriptor *pipeline_desc = [MTL4MeshRenderPipelineDescriptor new];
        pipeline_desc.label = @"heavy-slug mesh pipeline";
        pipeline_desc.objectFunctionDescriptor = function_descriptor(task_library, @"taskMain");
        pipeline_desc.meshFunctionDescriptor = function_descriptor(mesh_library, @"meshMain");
        pipeline_desc.fragmentFunctionDescriptor = function_descriptor(fragment_library, @"fragmentMain");
        pipeline_desc.maxTotalThreadsPerObjectThreadgroup = HS_METAL_TASK_THREADGROUP_SIZE;
        pipeline_desc.maxTotalThreadsPerMeshThreadgroup = HS_METAL_MESH_THREADGROUP_SIZE;
        pipeline_desc.requiredThreadsPerObjectThreadgroup = MTLSizeMake(HS_METAL_TASK_THREADGROUP_SIZE, 1, 1);
        pipeline_desc.requiredThreadsPerMeshThreadgroup = MTLSizeMake(HS_METAL_MESH_THREADGROUP_SIZE, 1, 1);
        pipeline_desc.payloadMemoryLength = HS_METAL_TASK_PAYLOAD_BYTES;
        pipeline_desc.maxTotalThreadgroupsPerMeshGrid = HS_METAL_TASK_MAX_MESHLETS;
        pipeline_desc.colorAttachments[0].pixelFormat = layer.pixelFormat;
        pipeline_desc.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
        pipeline_desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipeline_desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipeline_desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pipeline_desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipeline_desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipeline_desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        NSError *pipeline_error = nil;
        id<MTLRenderPipelineState> pipeline_state =
            [compiler newRenderPipelineStateWithDescriptor:pipeline_desc
                                       compilerTaskOptions:nil
                                                     error:&pipeline_error];
        if (!pipeline_state) {
            write_error(error_buffer, error_buffer_len, pipeline_error.localizedDescription);
            return nullptr;
        }

        hs_metal_context *context = new hs_metal_context();
        context->device = device;
        context->command_queue = command_queue;
        context->compiler = compiler;
        context->pipeline_state = pipeline_state;
        context->layer = layer;
        for (uint32_t i = 0; i < kFrameSlotCount; i++) {
            context->frame_slots[i].semaphore = dispatch_semaphore_create(1);
            context->frame_slots[i].allocator = [device newCommandAllocator];
            if (!context->frame_slots[i].allocator) {
                write_error(error_buffer, error_buffer_len, @"newCommandAllocator returned nil");
                delete context;
                return nullptr;
            }

            NSString *label = [NSString stringWithFormat:@"heavy-slug argument table %u", i];
            context->frame_slots[i].argument_table = make_argument_table(device, label, error_buffer, error_buffer_len);
            if (!context->frame_slots[i].argument_table) {
                delete context;
                return nullptr;
            }

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

    [slot->allocator reset];
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

hs_metal_resource_indices hs_metal_get_resource_indices(void) {
    return hs_metal_resource_indices{
        HS_METAL_BUFFER_GLYPH_POOL,
        HS_METAL_BUFFER_COMMANDS,
        HS_METAL_BUFFER_PUSH_CONSTANTS,
        HS_METAL_BUFFER_SHADER_STATS,
    };
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
    hs_metal_buffer *shader_stats,
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

        MTL4RenderPassDescriptor *pass_desc = [MTL4RenderPassDescriptor new];
        pass_desc.colorAttachments[0].texture = drawable.texture;
        pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass_desc.colorAttachments[0].clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);

        id<MTL4CommandBuffer> cb = [context->device newCommandBuffer];
        if (!cb) {
            write_error(error_buffer, error_buffer_len, @"newCommandBuffer returned nil");
            hs_metal_context_release_frame_slot(context, slot_index);
            return 0;
        }
        [cb beginCommandBufferWithAllocator:slot->allocator];

        id<MTL4RenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass_desc];
        if (!encoder) {
            write_error(error_buffer, error_buffer_len, @"renderCommandEncoderWithDescriptor returned nil");
            [cb endCommandBuffer];
            hs_metal_context_release_frame_slot(context, slot_index);
            return 0;
        }

        bind_buffer(slot->argument_table, glyph_pool, HS_METAL_BUFFER_GLYPH_POOL);
        bind_buffer(slot->argument_table, commands, HS_METAL_BUFFER_COMMANDS);
        bind_buffer(slot->argument_table, push_constants, HS_METAL_BUFFER_PUSH_CONSTANTS);
        if (shader_stats) {
            bind_buffer(slot->argument_table, shader_stats, HS_METAL_BUFFER_SHADER_STATS);
        }

        [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        [encoder setRenderPipelineState:context->pipeline_state];
        [encoder setArgumentTable:slot->argument_table
                         atStages:(MTLRenderStageObject | MTLRenderStageMesh | MTLRenderStageFragment)];
        [encoder drawMeshThreadgroups:MTLSizeMake(workgroup_count, 1, 1)
            threadsPerObjectThreadgroup:MTLSizeMake(HS_METAL_TASK_THREADGROUP_SIZE, 1, 1)
              threadsPerMeshThreadgroup:MTLSizeMake(HS_METAL_MESH_THREADGROUP_SIZE, 1, 1)];
        [encoder endEncoding];
        [cb endCommandBuffer];

        MTL4CommitOptions *commit_options = [MTL4CommitOptions new];
        slot->reserved = false;
        slot->in_flight = true;
        slot->failed = false;
        slot->message = nil;
        [commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            NSError *error = feedback.error;
            if (error) {
                slot->failed = true;
                slot->message = error.localizedDescription;
            }
            slot->in_flight = false;
            dispatch_semaphore_signal(slot->semaphore);
        }];

        id<MTL4CommandBuffer> command_buffers[1] = { cb };
        [context->command_queue waitForDrawable:drawable];
        [context->command_queue commit:command_buffers count:1 options:commit_options];
        [context->command_queue signalDrawable:drawable];
        [drawable present];
        return 1;
    }
}
