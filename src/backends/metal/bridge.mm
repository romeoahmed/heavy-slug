// Objective-C++ bridge for the Metal renderer ABI exposed to Zig.

#include "bridge.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>

static constexpr uint32_t kFrameSlotCount = 3;
static constexpr uint32_t kArgumentTableBufferBindCount = HEAVY_SLUG_SHADER_STATS ? 4 : 3;

struct hs_metal_frame_slot {
    __strong dispatch_semaphore_t semaphore;
    __strong id<MTL4CommandAllocator> allocator;
    __strong id<MTL4ArgumentTable> argument_table;
    bool reserved;
    bool failed;
    __strong NSString *message;
};

struct hs_metal_context {
    __unsafe_unretained id<MTLDevice> device;
    __unsafe_unretained id<MTL4CommandQueue> command_queue;
    __strong id<MTLRenderPipelineState> pipeline_state;
    __strong id<MTLResidencySet> residency_set;
    __unsafe_unretained CAMetalLayer *layer;
    MTLPixelFormat color_format;
    hs_metal_frame_slot frame_slots[kFrameSlotCount];
};

struct hs_metal_buffer {
    hs_metal_context *context;
    __strong id<MTLBuffer> buffer;
};

static void write_error(char *buffer, size_t len, NSString *message) {
    if (buffer == nullptr || len == 0) return;
    const char *text = message ? [message UTF8String] : "unknown Metal error";
    snprintf(buffer, len, "%s", text);
}

static void write_nserror(char *buffer, size_t len, NSString *prefix, NSError *error) {
    if (error.localizedDescription.length > 0) {
        write_error(buffer, len, [NSString stringWithFormat:@"%@: %@", prefix, error.localizedDescription]);
    } else {
        write_error(buffer, len, prefix);
    }
}

static bool validate_host(
    hs_metal_host_objects host,
    id<MTLDevice> *out_device,
    id<MTL4CommandQueue> *out_command_queue,
    CAMetalLayer **out_layer,
    char *error_buffer,
    size_t error_buffer_len) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)host.device;
    if (!device) {
        write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil MTLDevice");
        return false;
    }

    if (![device supportsFamily:MTLGPUFamilyMetal4]) {
        write_error(error_buffer, error_buffer_len, @"heavy-slug metal4 requires a Metal 4 family GPU");
        return false;
    }

    id<MTL4CommandQueue> command_queue = (__bridge id<MTL4CommandQueue>)host.command_queue;
    if (!command_queue) {
        write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil MTL4CommandQueue");
        return false;
    }
    if (command_queue.device != device) {
        write_error(error_buffer, error_buffer_len, @"Metal context received a command queue from a different device");
        return false;
    }

    CAMetalLayer *layer = (__bridge CAMetalLayer *)host.layer;
    if (!layer) {
        write_error(error_buffer, error_buffer_len, @"Metal context creation received a nil CAMetalLayer");
        return false;
    }
    if (layer.device != device) {
        write_error(error_buffer, error_buffer_len, @"Metal context received a CAMetalLayer from a different device");
        return false;
    }
    if (layer.pixelFormat == MTLPixelFormatInvalid) {
        write_error(error_buffer, error_buffer_len, @"Metal context received a CAMetalLayer with an invalid pixelFormat");
        return false;
    }

    *out_device = device;
    *out_command_queue = command_queue;
    *out_layer = layer;
    return true;
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
        write_nserror(error_buffer, error_buffer_len, [NSString stringWithFormat:@"failed to compile %@", name], error);
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
    descriptor.maxBufferBindCount = kArgumentTableBufferBindCount;
    descriptor.maxTextureBindCount = 0;
    descriptor.maxSamplerStateBindCount = 0;
    descriptor.initializeBindings = YES;
    descriptor.label = label;

    NSError *error = nil;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:descriptor error:&error];
    if (!table) {
        write_nserror(error_buffer, error_buffer_len, @"failed to create Metal argument table", error);
        return nil;
    }
    return table;
}

static id<MTL4CommandAllocator> make_command_allocator(
    id<MTLDevice> device,
    NSString *label,
    char *error_buffer,
    size_t error_buffer_len) {
    MTL4CommandAllocatorDescriptor *descriptor = [MTL4CommandAllocatorDescriptor new];
    descriptor.label = label;

    NSError *error = nil;
    id<MTL4CommandAllocator> allocator = [device newCommandAllocatorWithDescriptor:descriptor error:&error];
    if (!allocator) {
        write_nserror(error_buffer, error_buffer_len, @"failed to create Metal command allocator", error);
        return nil;
    }
    return allocator;
}

static id<MTLRenderPipelineState> make_pipeline_state(
    id<MTL4Compiler> compiler,
    MTLPixelFormat color_format,
    const char *task_source,
    size_t task_source_len,
    const char *mesh_source,
    size_t mesh_source_len,
    const char *fragment_source,
    size_t fragment_source_len,
    char *error_buffer,
    size_t error_buffer_len) {
    id<MTLLibrary> task_library = make_library(compiler, task_source, task_source_len, @"heavy-slug task", error_buffer, error_buffer_len);
    if (!task_library) return nil;
    id<MTLLibrary> mesh_library = make_library(compiler, mesh_source, mesh_source_len, @"heavy-slug mesh", error_buffer, error_buffer_len);
    if (!mesh_library) return nil;
    id<MTLLibrary> fragment_library = make_library(compiler, fragment_source, fragment_source_len, @"heavy-slug fragment", error_buffer, error_buffer_len);
    if (!fragment_library) return nil;

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
    pipeline_desc.rasterSampleCount = 1;
    pipeline_desc.alphaToCoverageState = MTL4AlphaToCoverageStateDisabled;
    pipeline_desc.alphaToOneState = MTL4AlphaToOneStateDisabled;
    pipeline_desc.rasterizationEnabled = YES;
    pipeline_desc.supportIndirectCommandBuffers = MTL4IndirectCommandBufferSupportStateDisabled;
    pipeline_desc.colorAttachments[0].pixelFormat = color_format;
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
        write_nserror(error_buffer, error_buffer_len, @"failed to create Metal mesh render pipeline", pipeline_error);
        return nil;
    }
    return pipeline_state;
}

static id<MTLResidencySet> make_residency_set(
    id<MTLDevice> device,
    char *error_buffer,
    size_t error_buffer_len) {
    MTLResidencySetDescriptor *residency_desc = [MTLResidencySetDescriptor new];
    residency_desc.label = @"heavy-slug residency set";
    residency_desc.initialCapacity = 8;

    NSError *residency_error = nil;
    id<MTLResidencySet> residency_set = [device newResidencySetWithDescriptor:residency_desc
                                                                        error:&residency_error];
    if (!residency_set) {
        write_nserror(error_buffer, error_buffer_len, @"failed to create Metal residency set", residency_error);
        return nil;
    }
    return residency_set;
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
        id<MTLDevice> device = nil;
        id<MTL4CommandQueue> command_queue = nil;
        CAMetalLayer *layer = nil;
        if (!validate_host(host, &device, &command_queue, &layer, error_buffer, error_buffer_len)) {
            return nullptr;
        }

        NSError *compiler_error = nil;
        MTL4CompilerDescriptor *compiler_desc = [MTL4CompilerDescriptor new];
        compiler_desc.label = @"heavy-slug compiler";
        id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:compiler_desc error:&compiler_error];
        if (!compiler) {
            write_nserror(error_buffer, error_buffer_len, @"failed to create Metal compiler", compiler_error);
            return nullptr;
        }

        id<MTLRenderPipelineState> pipeline_state = make_pipeline_state(
            compiler,
            layer.pixelFormat,
            task_source,
            task_source_len,
            mesh_source,
            mesh_source_len,
            fragment_source,
            fragment_source_len,
            error_buffer,
            error_buffer_len);
        if (!pipeline_state) {
            return nullptr;
        }

        id<MTLResidencySet> residency_set = make_residency_set(device, error_buffer, error_buffer_len);
        if (!residency_set) {
            return nullptr;
        }

        hs_metal_context *context = new hs_metal_context();
        context->device = device;
        context->command_queue = command_queue;
        context->pipeline_state = pipeline_state;
        context->residency_set = residency_set;
        context->layer = layer;
        context->color_format = layer.pixelFormat;
        for (uint32_t i = 0; i < kFrameSlotCount; i++) {
            context->frame_slots[i].semaphore = dispatch_semaphore_create(1);
            if (!context->frame_slots[i].semaphore) {
                write_error(error_buffer, error_buffer_len, @"dispatch_semaphore_create returned nil");
                delete context;
                return nullptr;
            }

            NSString *allocator_label = [NSString stringWithFormat:@"heavy-slug command allocator %u", i];
            context->frame_slots[i].allocator = make_command_allocator(
                device,
                allocator_label,
                error_buffer,
                error_buffer_len);
            if (!context->frame_slots[i].allocator) {
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
        dispatch_semaphore_wait(slot->semaphore, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_signal(slot->semaphore);
    }
}

void hs_metal_context_destroy(hs_metal_context *context) {
    if (!context) return;
    hs_metal_context_wait_submitted(context);
    delete context;
}

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context, size_t size) {
    if (!context || size == 0) return nullptr;
    @autoreleasepool {
        id<MTLBuffer> buffer = [context->device newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (!buffer) return nullptr;
        buffer.label = @"heavy-slug buffer";
        hs_metal_buffer *result = new hs_metal_buffer();
        result->context = context;
        result->buffer = buffer;
        [context->residency_set addAllocation:buffer];
        [context->residency_set commit];
        return result;
    }
}

void hs_metal_buffer_destroy(hs_metal_buffer *buffer) {
    if (buffer && buffer->context && buffer->buffer) {
        [buffer->context->residency_set removeAllocation:buffer->buffer];
        [buffer->context->residency_set commit];
    }
    delete buffer;
}

void *hs_metal_buffer_contents(hs_metal_buffer *buffer) {
    if (!buffer) return nullptr;
    return [buffer->buffer contents];
}

hs_metal_resource_indices hs_metal_get_resource_indices(void) {
    return hs_metal_resource_indices{
        HS_METAL_BUFFER_GLYPH_POOL,
        HS_METAL_BUFFER_GLYPHS,
        HS_METAL_BUFFER_FRAME_PARAMS,
        HS_METAL_BUFFER_SHADER_STATS,
    };
}

hs_metal_geometry_limits hs_metal_get_geometry_limits(void) {
    return hs_metal_geometry_limits{
        HS_METAL_TASK_THREADGROUP_SIZE,
        HS_METAL_MESH_THREADGROUP_SIZE,
        HS_METAL_TASK_MAX_MESHLETS,
        HS_METAL_TASK_PAYLOAD_BYTES,
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
    hs_metal_buffer *glyphs,
    hs_metal_buffer *frame_params,
    hs_metal_buffer *glyph_pool,
    hs_metal_buffer *shader_stats,
    uint32_t workgroup_count,
    uint32_t slot_index,
    char *error_buffer,
    size_t error_buffer_len) {
    @autoreleasepool {
        if (!context || !glyphs || !frame_params || !glyph_pool) {
            write_error(error_buffer, error_buffer_len, @"Metal draw received a null handle");
            return 0;
        }
#if HEAVY_SLUG_SHADER_STATS
        if (!shader_stats) {
            write_error(error_buffer, error_buffer_len, @"Metal draw requires a shader-stats buffer");
            return 0;
        }
#endif
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
        if (context->layer.pixelFormat != context->color_format) {
            write_error(error_buffer, error_buffer_len, @"CAMetalLayer pixelFormat changed after Metal pipeline creation");
            hs_metal_context_release_frame_slot(context, slot_index);
            return 0;
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
        cb.label = @"heavy-slug draw";
        [cb beginCommandBufferWithAllocator:slot->allocator];
        [cb useResidencySet:context->residency_set];

        id<MTL4RenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass_desc];
        if (!encoder) {
            write_error(error_buffer, error_buffer_len, @"renderCommandEncoderWithDescriptor returned nil");
            [cb endCommandBuffer];
            hs_metal_context_release_frame_slot(context, slot_index);
            return 0;
        }

        bind_buffer(slot->argument_table, glyph_pool, HS_METAL_BUFFER_GLYPH_POOL);
        bind_buffer(slot->argument_table, glyphs, HS_METAL_BUFFER_GLYPHS);
        bind_buffer(slot->argument_table, frame_params, HS_METAL_BUFFER_FRAME_PARAMS);
#if HEAVY_SLUG_SHADER_STATS
        bind_buffer(slot->argument_table, shader_stats, HS_METAL_BUFFER_SHADER_STATS);
#endif

        [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        [encoder setScissorRect:(MTLScissorRect){0, 0, width, height}];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setTriangleFillMode:MTLTriangleFillModeFill];
        [encoder setDepthClipMode:MTLDepthClipModeClip];
        [encoder setDepthStencilState:nil];
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
        slot->failed = false;
        slot->message = nil;
        [commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            @autoreleasepool {
                NSError *error = feedback.error;
                if (error) {
                    slot->failed = true;
                    slot->message = [error.localizedDescription copy];
                }
                dispatch_semaphore_signal(slot->semaphore);
            }
        }];

        id<MTL4CommandBuffer> command_buffers[1] = { cb };
        [context->command_queue waitForDrawable:drawable];
        [context->command_queue commit:command_buffers count:1 options:commit_options];
        [context->command_queue signalDrawable:drawable];
        [drawable present];
        return 1;
    }
}
