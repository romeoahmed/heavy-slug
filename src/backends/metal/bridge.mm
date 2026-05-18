// Objective-C++ bridge for the Metal renderer ABI exposed to Zig.

#include "bridge.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <dispatch/dispatch.h>
#include <memory>
#include <optional>
#include <span>
#include <utility>

namespace {

constexpr std::size_t kFrameSlotCount = 3;
constexpr NSUInteger kArgumentTableBufferBindCount =
    HEAVY_SLUG_SHADER_STATS ? 5 : 4;

enum class BufferIndex : std::uint32_t {
  glyphPool = HS_METAL_BUFFER_GLYPH_POOL,
  glyphs = HS_METAL_BUFFER_GLYPHS,
  meshlets = HS_METAL_BUFFER_MESHLETS,
  frameParams = HS_METAL_BUFFER_FRAME_PARAMS,
  shaderStats = HS_METAL_BUFFER_SHADER_STATS,
};

[[nodiscard]] constexpr NSUInteger bufferIndex(BufferIndex index) noexcept {
  return static_cast<NSUInteger>(std::to_underlying(index));
}

} // namespace

struct hs_metal_frame_slot {
  __strong dispatch_semaphore_t semaphore = nullptr;
  __strong id<MTL4CommandAllocator> allocator = nil;
  __strong id<MTL4ArgumentTable> argument_table = nil;
  bool reserved = false;
  bool failed = false;
  __strong NSString *message = nil;
};

struct hs_metal_context {
  __unsafe_unretained id<MTLDevice> device = nil;
  __unsafe_unretained id<MTL4CommandQueue> command_queue = nil;
  __strong id<MTLRenderPipelineState> pipeline_state = nil;
  __strong id<MTLResidencySet> residency_set = nil;
  __unsafe_unretained CAMetalLayer *layer = nil;
  MTLPixelFormat color_format = MTLPixelFormatInvalid;
  std::array<hs_metal_frame_slot, kFrameSlotCount> frame_slots{};

  hs_metal_context(id<MTLDevice> device_, id<MTL4CommandQueue> command_queue_,
                   id<MTLRenderPipelineState> pipeline_state_,
                   id<MTLResidencySet> residency_set_,
                   CAMetalLayer *layer_) noexcept
      : device(device_), command_queue(command_queue_),
        pipeline_state(pipeline_state_), residency_set(residency_set_),
        layer(layer_), color_format(layer_.pixelFormat) {}

  hs_metal_context(const hs_metal_context &) = delete;
  hs_metal_context &operator=(const hs_metal_context &) = delete;
};

struct hs_metal_buffer {
  hs_metal_context *context = nullptr;
  __strong id<MTLBuffer> buffer = nil;

  hs_metal_buffer(hs_metal_context *context_, id<MTLBuffer> buffer_) noexcept
      : context(context_), buffer(buffer_) {}

  hs_metal_buffer(const hs_metal_buffer &) = delete;
  hs_metal_buffer &operator=(const hs_metal_buffer &) = delete;
};

namespace {

class ErrorSink final {
public:
  explicit ErrorSink(std::span<char> buffer) noexcept : buffer_(buffer) {}

  void write(NSString *message) const {
    if (buffer_.empty())
      return;
    const char *text = message ? [message UTF8String] : "unknown Metal error";
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

struct HostObjects final {
  __unsafe_unretained id<MTLDevice> device = nil;
  __unsafe_unretained id<MTL4CommandQueue> command_queue = nil;
  __unsafe_unretained CAMetalLayer *layer = nil;
};

[[nodiscard]] std::span<char> errorBuffer(char *buffer,
                                          std::size_t len) noexcept {
  if (buffer == nullptr || len == 0)
    return {};
  return {buffer, len};
}

[[nodiscard]] std::optional<std::span<const char>>
sourceBuffer(const char *source, std::size_t len, NSString *name,
             const ErrorSink &error) {
  if (source == nullptr) {
    error.write([NSString stringWithFormat:@"%@ source pointer is null", name]);
    return std::nullopt;
  }
  if (len == 0) {
    error.write([NSString stringWithFormat:@"%@ source is empty", name]);
    return std::nullopt;
  }
  return std::span<const char>{source, len};
}

[[nodiscard]] bool validSlot(std::uint32_t slot_index) noexcept {
  return static_cast<std::size_t>(slot_index) < kFrameSlotCount;
}

[[nodiscard]] hs_metal_frame_slot &
frameSlot(hs_metal_context &context, std::uint32_t slot_index) noexcept {
  return context.frame_slots[static_cast<std::size_t>(slot_index)];
}

[[nodiscard]] std::span<hs_metal_frame_slot, kFrameSlotCount>
frameSlots(hs_metal_context &context) noexcept {
  return {context.frame_slots};
}

void releaseReservedSlot(hs_metal_frame_slot &slot) {
  if (!slot.reserved)
    return;
  slot.reserved = false;
  dispatch_semaphore_signal(slot.semaphore);
}

class ReservedSlotGuard final {
public:
  explicit ReservedSlotGuard(hs_metal_frame_slot &slot) noexcept
      : slot_(&slot) {}
  ~ReservedSlotGuard() {
    if (slot_ != nullptr)
      releaseReservedSlot(*slot_);
  }

  ReservedSlotGuard(const ReservedSlotGuard &) = delete;
  ReservedSlotGuard &operator=(const ReservedSlotGuard &) = delete;

  void disarm() noexcept {
    slot_ = nullptr;
  }

private:
  hs_metal_frame_slot *slot_;
};

[[nodiscard]] std::optional<HostObjects>
validateHost(hs_metal_host_objects host, const ErrorSink &error) {
  HostObjects result;
  result.device = (__bridge id<MTLDevice>)host.device;
  if (!result.device) {
    error.write(@"Metal context creation received a nil MTLDevice");
    return std::nullopt;
  }

  if (![result.device supportsFamily:MTLGPUFamilyMetal4]) {
    error.write(@"heavy-slug metal4 requires a Metal 4 family GPU");
    return std::nullopt;
  }

  result.command_queue = (__bridge id<MTL4CommandQueue>)host.command_queue;
  if (!result.command_queue) {
    error.write(@"Metal context creation received a nil MTL4CommandQueue");
    return std::nullopt;
  }
  if (result.command_queue.device != result.device) {
    error.write(
        @"Metal context received a command queue from a different device");
    return std::nullopt;
  }

  result.layer = (__bridge CAMetalLayer *)host.layer;
  if (!result.layer) {
    error.write(@"Metal context creation received a nil CAMetalLayer");
    return std::nullopt;
  }
  if (result.layer.device != result.device) {
    error.write(
        @"Metal context received a CAMetalLayer from a different device");
    return std::nullopt;
  }
  if (result.layer.pixelFormat == MTLPixelFormatInvalid) {
    error.write(
        @"Metal context received a CAMetalLayer with an invalid pixelFormat");
    return std::nullopt;
  }

  return result;
}

[[nodiscard]] id<MTLLibrary> makeLibrary(id<MTL4Compiler> compiler,
                                         std::span<const char> source,
                                         NSString *name,
                                         const ErrorSink &error) {
  NSString *source_string =
      [[NSString alloc] initWithBytes:source.data()
                               length:source.size()
                             encoding:NSUTF8StringEncoding];
  if (!source_string) {
    error.write(@"failed to create NSString for Metal source");
    return nil;
  }

  MTLCompileOptions *options = [MTLCompileOptions new];
  options.languageVersion = MTLLanguageVersion4_0;

  MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
  descriptor.source = source_string;
  descriptor.options = options;
  descriptor.name = name;

  NSError *ns_error = nil;
  id<MTLLibrary> library = [compiler newLibraryWithDescriptor:descriptor
                                                        error:&ns_error];
  if (!library) {
    error.write([NSString stringWithFormat:@"failed to compile %@", name],
                ns_error);
    return nil;
  }
  return library;
}

[[nodiscard]] MTL4LibraryFunctionDescriptor *
functionDescriptor(id<MTLLibrary> library, NSString *name) {
  MTL4LibraryFunctionDescriptor *descriptor =
      [MTL4LibraryFunctionDescriptor new];
  descriptor.library = library;
  descriptor.name = name;
  return descriptor;
}

[[nodiscard]] id<MTL4ArgumentTable> makeArgumentTable(id<MTLDevice> device,
                                                      NSString *label,
                                                      const ErrorSink &error) {
  MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
  descriptor.maxBufferBindCount = kArgumentTableBufferBindCount;
  descriptor.maxTextureBindCount = 0;
  descriptor.maxSamplerStateBindCount = 0;
  descriptor.initializeBindings = YES;
  descriptor.label = label;

  NSError *ns_error = nil;
  id<MTL4ArgumentTable> table =
      [device newArgumentTableWithDescriptor:descriptor error:&ns_error];
  if (!table) {
    error.write(@"failed to create Metal argument table", ns_error);
    return nil;
  }
  return table;
}

[[nodiscard]] id<MTL4CommandAllocator>
makeCommandAllocator(id<MTLDevice> device, NSString *label,
                     const ErrorSink &error) {
  MTL4CommandAllocatorDescriptor *descriptor =
      [MTL4CommandAllocatorDescriptor new];
  descriptor.label = label;

  NSError *ns_error = nil;
  id<MTL4CommandAllocator> allocator =
      [device newCommandAllocatorWithDescriptor:descriptor error:&ns_error];
  if (!allocator) {
    error.write(@"failed to create Metal command allocator", ns_error);
    return nil;
  }
  return allocator;
}

[[nodiscard]] id<MTLRenderPipelineState> makePipelineState(
    id<MTL4Compiler> compiler, MTLPixelFormat color_format,
    std::span<const char> mesh_source, std::span<const char> fragment_source,
    const ErrorSink &error) {
  id<MTLLibrary> mesh_library =
      makeLibrary(compiler, mesh_source, @"heavy-slug mesh", error);
  if (!mesh_library)
    return nil;
  id<MTLLibrary> fragment_library =
      makeLibrary(compiler, fragment_source, @"heavy-slug fragment", error);
  if (!fragment_library)
    return nil;

  MTL4MeshRenderPipelineDescriptor *pipeline_desc =
      [MTL4MeshRenderPipelineDescriptor new];
  pipeline_desc.label = @"heavy-slug mesh pipeline";
  pipeline_desc.objectFunctionDescriptor = nil;
  pipeline_desc.meshFunctionDescriptor =
      functionDescriptor(mesh_library, @"meshMain");
  pipeline_desc.fragmentFunctionDescriptor =
      functionDescriptor(fragment_library, @"fragmentMain");
  pipeline_desc.maxTotalThreadsPerObjectThreadgroup =
      HS_METAL_OBJECT_THREADGROUP_SIZE;
  pipeline_desc.maxTotalThreadsPerMeshThreadgroup =
      HS_METAL_MESH_THREADGROUP_SIZE;
  pipeline_desc.requiredThreadsPerObjectThreadgroup = MTLSizeMake(0, 0, 0);
  pipeline_desc.requiredThreadsPerMeshThreadgroup =
      MTLSizeMake(HS_METAL_MESH_THREADGROUP_SIZE, 1, 1);
  pipeline_desc.payloadMemoryLength = 0;
  pipeline_desc.maxTotalThreadgroupsPerMeshGrid =
      HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW;
  pipeline_desc.rasterSampleCount = 1;
  pipeline_desc.alphaToCoverageState = MTL4AlphaToCoverageStateDisabled;
  pipeline_desc.alphaToOneState = MTL4AlphaToOneStateDisabled;
  pipeline_desc.rasterizationEnabled = YES;
  pipeline_desc.supportIndirectCommandBuffers =
      MTL4IndirectCommandBufferSupportStateDisabled;
  pipeline_desc.colorAttachments[0].pixelFormat = color_format;
  pipeline_desc.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
  pipeline_desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  pipeline_desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  pipeline_desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  pipeline_desc.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  pipeline_desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  pipeline_desc.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;

  NSError *pipeline_error = nil;
  id<MTLRenderPipelineState> pipeline_state =
      [compiler newRenderPipelineStateWithDescriptor:pipeline_desc
                                 compilerTaskOptions:nil
                                               error:&pipeline_error];
  if (!pipeline_state) {
    error.write(@"failed to create Metal mesh render pipeline", pipeline_error);
    return nil;
  }
  return pipeline_state;
}

[[nodiscard]] id<MTLResidencySet> makeResidencySet(id<MTLDevice> device,
                                                   const ErrorSink &error) {
  MTLResidencySetDescriptor *residency_desc = [MTLResidencySetDescriptor new];
  residency_desc.label = @"heavy-slug residency set";
  residency_desc.initialCapacity = 8;

  NSError *residency_error = nil;
  id<MTLResidencySet> residency_set =
      [device newResidencySetWithDescriptor:residency_desc
                                      error:&residency_error];
  if (!residency_set) {
    error.write(@"failed to create Metal residency set", residency_error);
    return nil;
  }
  return residency_set;
}

void bindBuffer(id<MTL4ArgumentTable> table, hs_metal_buffer *buffer,
                BufferIndex index) {
  [table setAddress:buffer->buffer.gpuAddress atIndex:bufferIndex(index)];
}

} // namespace

hs_metal_context *
hs_metal_context_create(hs_metal_host_objects host, const char *mesh_source,
                        size_t mesh_source_len, const char *fragment_source,
                        size_t fragment_source_len, char *error_buffer,
                        size_t error_buffer_len) {
  @autoreleasepool {
    const ErrorSink error(errorBuffer(error_buffer, error_buffer_len));
    std::optional<HostObjects> host_objects = validateHost(host, error);
    if (!host_objects) {
      return nullptr;
    }

    std::optional<std::span<const char>> mesh_source_buffer =
        sourceBuffer(mesh_source, mesh_source_len, @"mesh shader", error);
    if (!mesh_source_buffer)
      return nullptr;
    std::optional<std::span<const char>> fragment_source_buffer = sourceBuffer(
        fragment_source, fragment_source_len, @"fragment shader", error);
    if (!fragment_source_buffer)
      return nullptr;

    NSError *compiler_error = nil;
    MTL4CompilerDescriptor *compiler_desc = [MTL4CompilerDescriptor new];
    compiler_desc.label = @"heavy-slug compiler";
    id<MTL4Compiler> compiler =
        [host_objects->device newCompilerWithDescriptor:compiler_desc
                                                  error:&compiler_error];
    if (!compiler) {
      error.write(@"failed to create Metal compiler", compiler_error);
      return nullptr;
    }

    id<MTLRenderPipelineState> pipeline_state = makePipelineState(
        compiler, host_objects->layer.pixelFormat, *mesh_source_buffer,
        *fragment_source_buffer, error);
    if (!pipeline_state) {
      return nullptr;
    }

    id<MTLResidencySet> residency_set =
        makeResidencySet(host_objects->device, error);
    if (!residency_set) {
      return nullptr;
    }

    auto context = std::make_unique<hs_metal_context>(
        host_objects->device, host_objects->command_queue, pipeline_state,
        residency_set, host_objects->layer);
    for (std::size_t i = 0; i < context->frame_slots.size(); i++) {
      hs_metal_frame_slot &slot = context->frame_slots[i];
      slot.semaphore = dispatch_semaphore_create(1);
      if (!slot.semaphore) {
        error.write(@"dispatch_semaphore_create returned nil");
        return nullptr;
      }

      const auto slot_number = static_cast<unsigned long>(i);
      NSString *allocator_label = [NSString
          stringWithFormat:@"heavy-slug command allocator %lu", slot_number];
      slot.allocator =
          makeCommandAllocator(host_objects->device, allocator_label, error);
      if (!slot.allocator) {
        return nullptr;
      }

      NSString *label = [NSString
          stringWithFormat:@"heavy-slug argument table %lu", slot_number];
      slot.argument_table =
          makeArgumentTable(host_objects->device, label, error);
      if (!slot.argument_table) {
        return nullptr;
      }
    }
    return context.release();
  }
}

int hs_metal_context_wait_frame_slot(hs_metal_context *context,
                                     uint32_t slot_index, char *error_buffer,
                                     size_t error_buffer_len) {
  const ErrorSink error(errorBuffer(error_buffer, error_buffer_len));
  if (!context || !validSlot(slot_index)) {
    error.write(@"invalid Metal frame slot");
    return 0;
  }

  hs_metal_frame_slot &slot = frameSlot(*context, slot_index);
  dispatch_semaphore_wait(slot.semaphore, DISPATCH_TIME_FOREVER);
  if (slot.failed) {
    error.write(slot.message);
    slot.failed = false;
    slot.message = nil;
    dispatch_semaphore_signal(slot.semaphore);
    return 0;
  }

  [slot.allocator reset];
  slot.reserved = true;
  return 1;
}

void hs_metal_context_release_frame_slot(hs_metal_context *context,
                                         uint32_t slot_index) {
  if (!context || !validSlot(slot_index))
    return;
  releaseReservedSlot(frameSlot(*context, slot_index));
}

void hs_metal_context_wait_submitted(hs_metal_context *context) {
  if (!context)
    return;
  for (hs_metal_frame_slot &slot : frameSlots(*context)) {
    dispatch_semaphore_wait(slot.semaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(slot.semaphore);
  }
}

void hs_metal_context_destroy(hs_metal_context *context) {
  if (!context)
    return;
  std::unique_ptr<hs_metal_context> owned(context);
  hs_metal_context_wait_submitted(owned.get());
}

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context,
                                        size_t size) {
  if (!context || size == 0)
    return nullptr;
  @autoreleasepool {
    id<MTLBuffer> buffer =
        [context->device newBufferWithLength:size
                                     options:MTLResourceStorageModeShared];
    if (!buffer)
      return nullptr;
    buffer.label = @"heavy-slug buffer";
    auto result = std::make_unique<hs_metal_buffer>(context, buffer);
    [context->residency_set addAllocation:buffer];
    [context->residency_set commit];
    return result.release();
  }
}

void hs_metal_buffer_destroy(hs_metal_buffer *buffer) {
  std::unique_ptr<hs_metal_buffer> owned(buffer);
  if (owned && owned->context && owned->buffer) {
    [owned->context->residency_set removeAllocation:owned->buffer];
    [owned->context->residency_set commit];
  }
}

void *hs_metal_buffer_contents(hs_metal_buffer *buffer) {
  if (!buffer)
    return nullptr;
  return [buffer->buffer contents];
}

hs_metal_resource_indices hs_metal_get_resource_indices(void) {
  return hs_metal_resource_indices{
      HS_METAL_BUFFER_GLYPH_POOL,
      HS_METAL_BUFFER_GLYPHS,
      HS_METAL_BUFFER_MESHLETS,
      HS_METAL_BUFFER_FRAME_PARAMS,
      HS_METAL_BUFFER_SHADER_STATS,
  };
}

hs_metal_geometry_limits hs_metal_get_geometry_limits(void) {
  return hs_metal_geometry_limits{
      HS_METAL_OBJECT_THREADGROUP_SIZE,
      HS_METAL_MESH_THREADGROUP_SIZE,
      HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW,
  };
}

int hs_metal_context_draw(hs_metal_context *context, uint32_t width,
                          uint32_t height, float clear_r, float clear_g,
                          float clear_b, float clear_a, hs_metal_buffer *glyphs,
                          hs_metal_buffer *meshlets,
                          hs_metal_buffer *frame_params,
                          uint32_t frame_params_stride,
                          hs_metal_buffer *glyph_pool,
                          hs_metal_buffer *shader_stats,
                          uint32_t workgroup_count, uint32_t slot_index,
                          char *error_buffer, size_t error_buffer_len) {
  @autoreleasepool {
    const ErrorSink error(errorBuffer(error_buffer, error_buffer_len));
#if !HEAVY_SLUG_SHADER_STATS
    (void)shader_stats;
#endif
    if (!context || !glyphs || !meshlets || !frame_params || !glyph_pool) {
      error.write(@"Metal draw received a null handle");
      return 0;
    }
#if HEAVY_SLUG_SHADER_STATS
    if (!shader_stats) {
      error.write(@"Metal draw requires a shader-stats buffer");
      return 0;
    }
#endif
    if (!validSlot(slot_index)) {
      error.write(@"invalid Metal frame slot");
      return 0;
    }
    hs_metal_frame_slot &slot = frameSlot(*context, slot_index);
    if (!slot.reserved) {
      error.write(@"Metal draw used an unreserved frame slot");
      return 0;
    }
    ReservedSlotGuard slot_guard(slot);
    if (workgroup_count == 0) {
      return 1;
    }
    if (frame_params_stride == 0) {
      error.write(@"Metal draw received a zero frame parameter stride");
      return 0;
    }
    if (context->layer.pixelFormat != context->color_format) {
      error.write(
          @"CAMetalLayer pixelFormat changed after Metal pipeline creation");
      return 0;
    }

    context->layer.drawableSize = CGSizeMake(width, height);
    id<CAMetalDrawable> drawable = [context->layer nextDrawable];
    if (!drawable) {
      error.write(@"CAMetalLayer nextDrawable returned nil");
      return 0;
    }

    MTL4RenderPassDescriptor *pass_desc = [MTL4RenderPassDescriptor new];
    pass_desc.colorAttachments[0].texture = drawable.texture;
    pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass_desc.colorAttachments[0].clearColor =
        MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);

    id<MTL4CommandBuffer> cb = [context->device newCommandBuffer];
    if (!cb) {
      error.write(@"newCommandBuffer returned nil");
      return 0;
    }
    cb.label = @"heavy-slug draw";
    [cb beginCommandBufferWithAllocator:slot.allocator];
    [cb useResidencySet:context->residency_set];

    id<MTL4RenderCommandEncoder> encoder =
        [cb renderCommandEncoderWithDescriptor:pass_desc];
    if (!encoder) {
      error.write(@"renderCommandEncoderWithDescriptor returned nil");
      [cb endCommandBuffer];
      return 0;
    }

    bindBuffer(slot.argument_table, glyph_pool, BufferIndex::glyphPool);
    bindBuffer(slot.argument_table, glyphs, BufferIndex::glyphs);
    bindBuffer(slot.argument_table, meshlets, BufferIndex::meshlets);
#if HEAVY_SLUG_SHADER_STATS
    bindBuffer(slot.argument_table, shader_stats, BufferIndex::shaderStats);
#endif

    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(width),
                                     static_cast<double>(height), 0.0, 1.0}];
    [encoder setScissorRect:MTLScissorRect{0, 0, width, height}];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setTriangleFillMode:MTLTriangleFillModeFill];
    [encoder setDepthClipMode:MTLDepthClipModeClip];
    [encoder setDepthStencilState:nil];
    [encoder setRenderPipelineState:context->pipeline_state];
    uint32_t meshlet_base = 0;
    uint32_t chunk_index = 0;
    while (meshlet_base < workgroup_count) {
      const uint32_t chunk_count =
          std::min(workgroup_count - meshlet_base,
                   static_cast<uint32_t>(
                       HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW));
      [slot.argument_table setAddress:(frame_params->buffer.gpuAddress +
                                       static_cast<NSUInteger>(chunk_index) *
                                           frame_params_stride)
                              atIndex:bufferIndex(BufferIndex::frameParams)];
      [encoder setArgumentTable:slot.argument_table
                       atStages:(MTLRenderStageMesh | MTLRenderStageFragment)];
      [encoder drawMeshThreadgroups:MTLSizeMake(chunk_count, 1, 1)
          threadsPerObjectThreadgroup:MTLSizeMake(0, 0, 0)
            threadsPerMeshThreadgroup:MTLSizeMake(
                                        HS_METAL_MESH_THREADGROUP_SIZE, 1, 1)];
      meshlet_base += chunk_count;
      chunk_index += 1;
    }
    [encoder endEncoding];
    [cb endCommandBuffer];

    MTL4CommitOptions *commit_options = [MTL4CommitOptions new];
    slot.reserved = false;
    slot_guard.disarm();
    slot.failed = false;
    slot.message = nil;
    hs_metal_frame_slot *submitted_slot = &slot;
    [commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
      @autoreleasepool {
        NSError *feedback_error = feedback.error;
        if (feedback_error) {
          submitted_slot->failed = true;
          submitted_slot->message = [feedback_error.localizedDescription copy];
        }
        dispatch_semaphore_signal(submitted_slot->semaphore);
      }
    }];

    std::array<id<MTL4CommandBuffer>, 1> command_buffers{cb};
    [context->command_queue waitForDrawable:drawable];
    [context->command_queue commit:command_buffers.data()
                             count:command_buffers.size()
                           options:commit_options];
    [context->command_queue signalDrawable:drawable];
    [drawable present];
    return 1;
  }
}
