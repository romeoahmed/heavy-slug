// Metal 4 renderer bridge exposed as a small C ABI for Zig.

#include "bridge.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <new>
#include <span>
#include <utility>

namespace {

constexpr std::size_t kFrameSlotCount = 3;
constexpr NSUInteger kBufferBindCount = HEAVY_SLUG_SHADER_STATS ? 5u : 4u;
constexpr MTLRenderStages kBoundRenderStages =
    MTLRenderStageMesh | MTLRenderStageFragment;

enum class BufferSlot : std::uint32_t {
  glyphPool = HS_METAL_BUFFER_GLYPH_POOL,
  glyphs = HS_METAL_BUFFER_GLYPHS,
  meshlets = HS_METAL_BUFFER_MESHLETS,
  frameParams = HS_METAL_BUFFER_FRAME_PARAMS,
  shaderStats = HS_METAL_BUFFER_SHADER_STATS,
};

[[nodiscard]] constexpr NSUInteger tableIndex(BufferSlot slot) noexcept {
  return static_cast<NSUInteger>(std::to_underlying(slot));
}

[[nodiscard]] constexpr MTLSize noObjectThreads() noexcept {
  return MTLSize{0, 0, 0};
}

[[nodiscard]] constexpr MTLSize meshThreads() noexcept {
  return MTLSize{HS_METAL_MESH_THREADGROUP_SIZE, 1, 1};
}

[[nodiscard]] std::span<char> errorSpan(char *buffer,
                                        std::size_t length) noexcept {
  if (buffer == nullptr || length == 0) {
    return {};
  }
  return {buffer, length};
}

class ErrorSink final {
public:
  explicit ErrorSink(std::span<char> buffer) noexcept : buffer_(buffer) {
    if (!buffer_.empty()) {
      buffer_.front() = '\0';
    }
  }

  void write(NSString *message) const {
    if (buffer_.empty()) {
      return;
    }
    const char *text = message ? [message UTF8String] : "unknown Metal error";
    std::snprintf(buffer_.data(), buffer_.size(), "%s", text);
  }

  void write(NSString *prefix, NSError *error) const {
    if (error.localizedDescription.length > 0) {
      write([NSString stringWithFormat:@"%@: %@", prefix,
                                       error.localizedDescription]);
      return;
    }
    write(prefix);
  }

private:
  std::span<char> buffer_;
};

template <typename T, typename... Args>
[[nodiscard]] std::unique_ptr<T> allocate(Args &&...args) {
  return std::unique_ptr<T>(
      new (std::nothrow) T(std::forward<Args>(args)...));
}

struct ShaderText final {
  std::span<const char> bytes;
  __strong NSString *label = nil;
};

[[nodiscard]] bool loadShaderText(const char *source, std::size_t length,
                                  NSString *label, ShaderText &out,
                                  const ErrorSink &error) {
  if (source == nullptr) {
    error.write([NSString stringWithFormat:@"%@ source pointer is null", label]);
    return false;
  }
  if (length == 0) {
    error.write([NSString stringWithFormat:@"%@ source is empty", label]);
    return false;
  }
  out.bytes = std::span<const char>{source, length};
  out.label = label;
  return true;
}

struct HostObjects final {
  __strong id<MTLDevice> device = nil;
  __strong id<MTL4CommandQueue> commandQueue = nil;
  __strong CAMetalLayer *layer = nil;
  __strong id<MTLResidencySet> drawableResidency = nil;
  MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
};

[[nodiscard]] bool loadHostObjects(hs_metal_host_objects host,
                                   HostObjects &out,
                                   const ErrorSink &error) {
  id<MTLDevice> device = (__bridge id<MTLDevice>)host.device;
  if (!device) {
    error.write(@"Metal context creation received a nil MTLDevice");
    return false;
  }
  if (![device supportsFamily:MTLGPUFamilyMetal4]) {
    error.write(@"heavy-slug metal4 requires a Metal 4 family GPU");
    return false;
  }

  id<MTL4CommandQueue> command_queue =
      (__bridge id<MTL4CommandQueue>)host.command_queue;
  if (!command_queue) {
    error.write(@"Metal context creation received a nil MTL4CommandQueue");
    return false;
  }
  if (command_queue.device != device) {
    error.write(
        @"Metal context received a command queue from a different device");
    return false;
  }

  CAMetalLayer *layer = (__bridge CAMetalLayer *)host.layer;
  if (!layer) {
    error.write(@"Metal context creation received a nil CAMetalLayer");
    return false;
  }
  if (layer.device != device) {
    error.write(@"Metal context received a CAMetalLayer from a different device");
    return false;
  }
  if (layer.pixelFormat == MTLPixelFormatInvalid) {
    error.write(
        @"Metal context received a CAMetalLayer with an invalid pixelFormat");
    return false;
  }
  if (!layer.residencySet) {
    error.write(@"Metal context received a CAMetalLayer without a residency set");
    return false;
  }

  out.device = device;
  out.commandQueue = command_queue;
  out.layer = layer;
  out.drawableResidency = layer.residencySet;
  out.colorFormat = layer.pixelFormat;
  return true;
}

[[nodiscard]] id<MTLLibrary> makeLibrary(id<MTL4Compiler> compiler,
                                         const ShaderText &source,
                                         const ErrorSink &error) {
  NSString *source_string =
      [[NSString alloc] initWithBytes:source.bytes.data()
                               length:source.bytes.size()
                             encoding:NSUTF8StringEncoding];
  if (!source_string) {
    error.write([NSString stringWithFormat:@"failed to decode %@ as UTF-8",
                                           source.label]);
    return nil;
  }

  MTLCompileOptions *options = [MTLCompileOptions new];
  options.languageVersion = MTLLanguageVersion4_0;

  MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
  descriptor.name = source.label;
  descriptor.source = source_string;
  descriptor.options = options;

  NSError *library_error = nil;
  id<MTLLibrary> library = [compiler newLibraryWithDescriptor:descriptor
                                                        error:&library_error];
  if (!library) {
    error.write([NSString stringWithFormat:@"failed to compile %@",
                                           source.label],
                library_error);
    return nil;
  }
  return library;
}

[[nodiscard]] MTL4LibraryFunctionDescriptor *
libraryFunction(id<MTLLibrary> library, NSString *name) {
  MTL4LibraryFunctionDescriptor *descriptor =
      [MTL4LibraryFunctionDescriptor new];
  descriptor.library = library;
  descriptor.name = name;
  return descriptor;
}

[[nodiscard]] id<MTL4Compiler> makeCompiler(id<MTLDevice> device,
                                            const ErrorSink &error) {
  MTL4CompilerDescriptor *descriptor = [MTL4CompilerDescriptor new];
  descriptor.label = @"heavy-slug compiler";

  NSError *compiler_error = nil;
  id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:descriptor
                                                          error:&compiler_error];
  if (!compiler) {
    error.write(@"failed to create Metal compiler", compiler_error);
    return nil;
  }
  return compiler;
}

[[nodiscard]] id<MTLRenderPipelineState>
makePipeline(id<MTL4Compiler> compiler, MTLPixelFormat color_format,
             const ShaderText &mesh_source, const ShaderText &fragment_source,
             const ErrorSink &error) {
  id<MTLLibrary> mesh_library = makeLibrary(compiler, mesh_source, error);
  if (!mesh_library) {
    return nil;
  }

  id<MTLLibrary> fragment_library =
      makeLibrary(compiler, fragment_source, error);
  if (!fragment_library) {
    return nil;
  }

  MTL4MeshRenderPipelineDescriptor *descriptor =
      [MTL4MeshRenderPipelineDescriptor new];
  descriptor.label = @"heavy-slug mesh pipeline";
  descriptor.objectFunctionDescriptor = nil;
  descriptor.meshFunctionDescriptor = libraryFunction(mesh_library, @"meshMain");
  descriptor.fragmentFunctionDescriptor =
      libraryFunction(fragment_library, @"fragmentMain");
  descriptor.maxTotalThreadsPerObjectThreadgroup =
      HS_METAL_OBJECT_THREADGROUP_SIZE;
  descriptor.maxTotalThreadsPerMeshThreadgroup =
      HS_METAL_MESH_THREADGROUP_SIZE;
  descriptor.requiredThreadsPerObjectThreadgroup = noObjectThreads();
  descriptor.requiredThreadsPerMeshThreadgroup = meshThreads();
  descriptor.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth = NO;
  descriptor.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth = YES;
  descriptor.payloadMemoryLength = 0;
  descriptor.maxTotalThreadgroupsPerMeshGrid =
      HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW;
  descriptor.rasterSampleCount = 1;
  descriptor.alphaToCoverageState = MTL4AlphaToCoverageStateDisabled;
  descriptor.alphaToOneState = MTL4AlphaToOneStateDisabled;
  descriptor.rasterizationEnabled = YES;
  descriptor.supportIndirectCommandBuffers =
      MTL4IndirectCommandBufferSupportStateDisabled;

  auto *attachment = descriptor.colorAttachments[0];
  attachment.pixelFormat = color_format;
  attachment.blendingState = MTL4BlendStateEnabled;
  attachment.rgbBlendOperation = MTLBlendOperationAdd;
  attachment.alphaBlendOperation = MTLBlendOperationAdd;
  attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
  attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
  attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

  NSError *pipeline_error = nil;
  id<MTLRenderPipelineState> pipeline =
      [compiler newRenderPipelineStateWithDescriptor:descriptor
                                 compilerTaskOptions:nil
                                               error:&pipeline_error];
  if (!pipeline) {
    error.write(@"failed to create Metal mesh render pipeline", pipeline_error);
    return nil;
  }
  return pipeline;
}

[[nodiscard]] id<MTLResidencySet> makeResidencySet(id<MTLDevice> device,
                                                   const ErrorSink &error) {
  MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new];
  descriptor.label = @"heavy-slug resources";
  descriptor.initialCapacity = 8;

  NSError *residency_error = nil;
  id<MTLResidencySet> residency =
      [device newResidencySetWithDescriptor:descriptor error:&residency_error];
  if (!residency) {
    error.write(@"failed to create Metal residency set", residency_error);
    return nil;
  }
  return residency;
}

[[nodiscard]] id<MTL4ArgumentTable>
makeArgumentTable(id<MTLDevice> device, NSUInteger slot_index,
                  const ErrorSink &error) {
  MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
  descriptor.maxBufferBindCount = kBufferBindCount;
  descriptor.maxTextureBindCount = 0;
  descriptor.maxSamplerStateBindCount = 0;
  descriptor.initializeBindings = YES;
  descriptor.supportAttributeStrides = NO;
  descriptor.label =
      [NSString stringWithFormat:@"heavy-slug arguments %zu",
                                 static_cast<std::size_t>(slot_index)];

  NSError *argument_error = nil;
  id<MTL4ArgumentTable> table =
      [device newArgumentTableWithDescriptor:descriptor error:&argument_error];
  if (!table) {
    error.write(@"failed to create Metal argument table", argument_error);
    return nil;
  }
  return table;
}

[[nodiscard]] id<MTL4CommandAllocator>
makeCommandAllocator(id<MTLDevice> device, NSUInteger slot_index,
                     const ErrorSink &error) {
  MTL4CommandAllocatorDescriptor *descriptor =
      [MTL4CommandAllocatorDescriptor new];
  descriptor.label =
      [NSString stringWithFormat:@"heavy-slug command allocator %zu",
                                 static_cast<std::size_t>(slot_index)];

  NSError *allocator_error = nil;
  id<MTL4CommandAllocator> allocator =
      [device newCommandAllocatorWithDescriptor:descriptor
                                          error:&allocator_error];
  if (!allocator) {
    error.write(@"failed to create Metal command allocator", allocator_error);
    return nil;
  }
  return allocator;
}

} // namespace

struct hs_metal_frame_slot final {
  __strong dispatch_semaphore_t semaphore = nullptr;
  __strong id<MTL4CommandAllocator> allocator = nil;
  __strong id<MTL4ArgumentTable> arguments = nil;
  bool reserved = false;
  bool failed = false;
  __strong NSString *failureMessage = nil;

  hs_metal_frame_slot() = default;
  hs_metal_frame_slot(const hs_metal_frame_slot &) = delete;
  hs_metal_frame_slot &operator=(const hs_metal_frame_slot &) = delete;

  [[nodiscard]] bool init(id<MTLDevice> device, NSUInteger index,
                          const ErrorSink &error) {
    semaphore = dispatch_semaphore_create(1);
    if (!semaphore) {
      error.write(@"dispatch_semaphore_create returned nil");
      return false;
    }
    allocator = makeCommandAllocator(device, index, error);
    if (!allocator) {
      return false;
    }
    arguments = makeArgumentTable(device, index, error);
    return arguments != nil;
  }

  [[nodiscard]] bool reserve(const ErrorSink &error) {
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (failed) {
      error.write(failureMessage);
      failed = false;
      failureMessage = nil;
      dispatch_semaphore_signal(semaphore);
      return false;
    }

    [allocator reset];
    reserved = true;
    return true;
  }

  void releaseReservation() {
    if (!reserved) {
      return;
    }
    reserved = false;
    dispatch_semaphore_signal(semaphore);
  }

  void submit() {
    reserved = false;
    failed = false;
    failureMessage = nil;
  }

  void finish(id<MTL4CommitFeedback> feedback) {
    NSError *feedback_error = feedback.error;
    if (feedback_error) {
      failed = true;
      failureMessage = [feedback_error.localizedDescription copy];
    }
    dispatch_semaphore_signal(semaphore);
  }
};

namespace {

class SlotReservation final {
public:
  explicit SlotReservation(hs_metal_frame_slot &slot) noexcept : slot_(&slot) {}

  ~SlotReservation() {
    if (slot_ != nullptr) {
      slot_->releaseReservation();
    }
  }

  SlotReservation(const SlotReservation &) = delete;
  SlotReservation &operator=(const SlotReservation &) = delete;

  void disarm() noexcept { slot_ = nullptr; }

private:
  hs_metal_frame_slot *slot_;
};

} // namespace

struct hs_metal_context final {
  __strong id<MTLDevice> device = nil;
  __strong id<MTL4CommandQueue> commandQueue = nil;
  __strong CAMetalLayer *layer = nil;
  __strong id<MTLRenderPipelineState> pipeline = nil;
  __strong id<MTLResidencySet> resourceResidency = nil;
  __strong id<MTLResidencySet> drawableResidency = nil;
  MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
  std::array<hs_metal_frame_slot, kFrameSlotCount> slots{};

  hs_metal_context(const HostObjects &host, id<MTLRenderPipelineState> pipeline_,
                   id<MTLResidencySet> resource_residency) noexcept
      : device(host.device), commandQueue(host.commandQueue), layer(host.layer),
        pipeline(pipeline_), resourceResidency(resource_residency),
        drawableResidency(host.drawableResidency), colorFormat(host.colorFormat) {
  }

  hs_metal_context(const hs_metal_context &) = delete;
  hs_metal_context &operator=(const hs_metal_context &) = delete;
};

struct hs_metal_buffer final {
  hs_metal_context *owner = nullptr;
  __strong id<MTLBuffer> buffer = nil;

  hs_metal_buffer(hs_metal_context *context, id<MTLBuffer> buffer_) noexcept
      : owner(context), buffer(buffer_) {}

  hs_metal_buffer(const hs_metal_buffer &) = delete;
  hs_metal_buffer &operator=(const hs_metal_buffer &) = delete;
};

namespace {

[[nodiscard]] bool validSlotIndex(std::uint32_t index) noexcept {
  return static_cast<std::size_t>(index) < kFrameSlotCount;
}

[[nodiscard]] hs_metal_frame_slot &slotAt(hs_metal_context &context,
                                          std::uint32_t index) noexcept {
  return context.slots[static_cast<std::size_t>(index)];
}

[[nodiscard]] bool bufferBelongsTo(hs_metal_context *context,
                                   hs_metal_buffer *buffer) noexcept {
  return context != nullptr && buffer != nullptr && buffer->owner == context &&
         buffer->buffer != nil;
}

void bindBuffer(id<MTL4ArgumentTable> table, hs_metal_buffer *buffer,
                BufferSlot slot) {
  [table setAddress:buffer->buffer.gpuAddress atIndex:tableIndex(slot)];
}

[[nodiscard]] bool bindFrameParams(id<MTL4ArgumentTable> table,
                                   hs_metal_buffer *frame_params,
                                   std::uint32_t chunk_index,
                                   std::uint32_t stride,
                                   const ErrorSink &error) {
  const auto offset =
      static_cast<MTLGPUAddress>(chunk_index) * static_cast<MTLGPUAddress>(stride);
  const MTLGPUAddress address = frame_params->buffer.gpuAddress + offset;
  if (address < frame_params->buffer.gpuAddress) {
    error.write(@"Metal frame parameter GPU address overflowed");
    return false;
  }
  [table setAddress:address atIndex:tableIndex(BufferSlot::frameParams)];
  return true;
}

[[nodiscard]] MTL4RenderPassDescriptor *
makeRenderPass(id<CAMetalDrawable> drawable, float clear_r, float clear_g,
               float clear_b, float clear_a) {
  MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor =
      MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);
  return pass;
}

[[nodiscard]] bool validateDrawBuffers(hs_metal_context *context,
                                       hs_metal_buffer *glyphs,
                                       hs_metal_buffer *meshlets,
                                       hs_metal_buffer *frame_params,
                                       hs_metal_buffer *glyph_pool,
                                       hs_metal_buffer *shader_stats,
                                       const ErrorSink &error) {
  if (!bufferBelongsTo(context, glyphs) || !bufferBelongsTo(context, meshlets) ||
      !bufferBelongsTo(context, frame_params) ||
      !bufferBelongsTo(context, glyph_pool)) {
    error.write(@"Metal draw received a null or foreign buffer handle");
    return false;
  }
#if HEAVY_SLUG_SHADER_STATS
  if (!bufferBelongsTo(context, shader_stats)) {
    error.write(@"Metal draw requires a shader-stats buffer from this context");
    return false;
  }
#else
  (void)shader_stats;
#endif
  return true;
}

void waitForSubmittedWork(hs_metal_context *context) {
  if (!context) {
    return;
  }
  for (hs_metal_frame_slot &slot : context->slots) {
    dispatch_semaphore_wait(slot.semaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(slot.semaphore);
  }
}

} // namespace

hs_metal_context *
hs_metal_context_create(hs_metal_host_objects host, const char *mesh_source,
                        size_t mesh_source_len, const char *fragment_source,
                        size_t fragment_source_len, char *error_buffer,
                        size_t error_buffer_len) {
  @autoreleasepool {
    const ErrorSink error(errorSpan(error_buffer, error_buffer_len));

    HostObjects host_objects;
    if (!loadHostObjects(host, host_objects, error)) {
      return nullptr;
    }

    ShaderText mesh_text;
    if (!loadShaderText(mesh_source, mesh_source_len, @"mesh shader", mesh_text,
                        error)) {
      return nullptr;
    }
    ShaderText fragment_text;
    if (!loadShaderText(fragment_source, fragment_source_len, @"fragment shader",
                        fragment_text, error)) {
      return nullptr;
    }

    id<MTL4Compiler> compiler = makeCompiler(host_objects.device, error);
    if (!compiler) {
      return nullptr;
    }

    id<MTLRenderPipelineState> pipeline =
        makePipeline(compiler, host_objects.colorFormat, mesh_text, fragment_text,
                     error);
    if (!pipeline) {
      return nullptr;
    }

    id<MTLResidencySet> resource_residency =
        makeResidencySet(host_objects.device, error);
    if (!resource_residency) {
      return nullptr;
    }

    auto context = allocate<hs_metal_context>(host_objects, pipeline,
                                              resource_residency);
    if (!context) {
      error.write(@"failed to allocate Metal context");
      return nullptr;
    }

    for (NSUInteger index = 0; index < context->slots.size(); index += 1) {
      if (!context->slots[index].init(host_objects.device, index, error)) {
        return nullptr;
      }
    }

    return context.release();
  }
}

void hs_metal_context_destroy(hs_metal_context *context) {
  if (!context) {
    return;
  }
  std::unique_ptr<hs_metal_context> owned(context);
  waitForSubmittedWork(owned.get());
}

int hs_metal_context_wait_frame_slot(hs_metal_context *context,
                                     uint32_t slot_index, char *error_buffer,
                                     size_t error_buffer_len) {
  const ErrorSink error(errorSpan(error_buffer, error_buffer_len));
  if (!context || !validSlotIndex(slot_index)) {
    error.write(@"invalid Metal frame slot");
    return 0;
  }
  return slotAt(*context, slot_index).reserve(error) ? 1 : 0;
}

void hs_metal_context_release_frame_slot(hs_metal_context *context,
                                         uint32_t slot_index) {
  if (!context || !validSlotIndex(slot_index)) {
    return;
  }
  slotAt(*context, slot_index).releaseReservation();
}

void hs_metal_context_wait_submitted(hs_metal_context *context) {
  waitForSubmittedWork(context);
}

hs_metal_buffer *hs_metal_buffer_create(hs_metal_context *context, size_t size) {
  if (!context || size == 0 ||
      size > static_cast<std::size_t>(std::numeric_limits<NSUInteger>::max())) {
    return nullptr;
  }

  @autoreleasepool {
    id<MTLBuffer> buffer =
        [context->device newBufferWithLength:static_cast<NSUInteger>(size)
                                     options:MTLResourceStorageModeShared];
    if (!buffer) {
      return nullptr;
    }
    buffer.label = @"heavy-slug buffer";

    auto wrapper = allocate<hs_metal_buffer>(context, buffer);
    if (!wrapper) {
      return nullptr;
    }

    [context->resourceResidency addAllocation:buffer];
    [context->resourceResidency commit];
    return wrapper.release();
  }
}

void hs_metal_buffer_destroy(hs_metal_buffer *buffer) {
  std::unique_ptr<hs_metal_buffer> owned(buffer);
  if (owned && owned->owner && owned->buffer) {
    [owned->owner->resourceResidency removeAllocation:owned->buffer];
    [owned->owner->resourceResidency commit];
  }
}

void *hs_metal_buffer_contents(hs_metal_buffer *buffer) {
  if (!buffer) {
    return nullptr;
  }
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
    const ErrorSink error(errorSpan(error_buffer, error_buffer_len));
    if (!context) {
      error.write(@"Metal draw received a null context");
      return 0;
    }
    if (!validateDrawBuffers(context, glyphs, meshlets, frame_params, glyph_pool,
                             shader_stats, error)) {
      return 0;
    }
    if (!validSlotIndex(slot_index)) {
      error.write(@"invalid Metal frame slot");
      return 0;
    }

    hs_metal_frame_slot &slot = slotAt(*context, slot_index);
    if (!slot.reserved) {
      error.write(@"Metal draw used an unreserved frame slot");
      return 0;
    }
    SlotReservation reservation(slot);

    if (workgroup_count == 0) {
      return 1;
    }
    if (width == 0 || height == 0) {
      error.write(@"Metal draw requires a nonzero viewport");
      return 0;
    }
    if (frame_params_stride == 0) {
      error.write(@"Metal draw received a zero frame parameter stride");
      return 0;
    }
    if (context->layer.pixelFormat != context->colorFormat) {
      error.write(
          @"CAMetalLayer pixelFormat changed after Metal pipeline creation");
      return 0;
    }

    context->layer.drawableSize =
        CGSizeMake(static_cast<CGFloat>(width), static_cast<CGFloat>(height));
    id<CAMetalDrawable> drawable = [context->layer nextDrawable];
    if (!drawable) {
      error.write(@"CAMetalLayer nextDrawable returned nil");
      return 0;
    }

    MTL4RenderPassDescriptor *pass =
        makeRenderPass(drawable, clear_r, clear_g, clear_b, clear_a);
    id<MTL4CommandBuffer> command_buffer = [context->device newCommandBuffer];
    if (!command_buffer) {
      error.write(@"newCommandBuffer returned nil");
      return 0;
    }
    command_buffer.label = @"heavy-slug draw";
    [command_buffer beginCommandBufferWithAllocator:slot.allocator];
    [command_buffer useResidencySet:context->resourceResidency];
    [command_buffer useResidencySet:context->drawableResidency];

    id<MTL4RenderCommandEncoder> encoder =
        [command_buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
      error.write(@"renderCommandEncoderWithDescriptor returned nil");
      [command_buffer endCommandBuffer];
      return 0;
    }

    bindBuffer(slot.arguments, glyph_pool, BufferSlot::glyphPool);
    bindBuffer(slot.arguments, glyphs, BufferSlot::glyphs);
    bindBuffer(slot.arguments, meshlets, BufferSlot::meshlets);
#if HEAVY_SLUG_SHADER_STATS
    bindBuffer(slot.arguments, shader_stats, BufferSlot::shaderStats);
#endif

    [encoder setViewport:MTLViewport{0.0, 0.0, static_cast<double>(width),
                                     static_cast<double>(height), 0.0, 1.0}];
    [encoder setScissorRect:MTLScissorRect{0, 0, width, height}];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setTriangleFillMode:MTLTriangleFillModeFill];
    [encoder setDepthClipMode:MTLDepthClipModeClip];
    [encoder setDepthStencilState:nil];
    [encoder setRenderPipelineState:context->pipeline];

    std::uint32_t meshlet_base = 0;
    std::uint32_t chunk_index = 0;
    while (meshlet_base < workgroup_count) {
      const std::uint32_t chunk_count =
          std::min(workgroup_count - meshlet_base,
                   static_cast<std::uint32_t>(
                       HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW));
      if (!bindFrameParams(slot.arguments, frame_params, chunk_index,
                           frame_params_stride, error)) {
        [encoder endEncoding];
        [command_buffer endCommandBuffer];
        return 0;
      }
      [encoder setArgumentTable:slot.arguments atStages:kBoundRenderStages];
      [encoder drawMeshThreadgroups:MTLSize{chunk_count, 1, 1}
          threadsPerObjectThreadgroup:noObjectThreads()
            threadsPerMeshThreadgroup:meshThreads()];
      meshlet_base += chunk_count;
      chunk_index += 1;
    }

    [encoder endEncoding];
    [command_buffer endCommandBuffer];

    MTL4CommitOptions *commit_options = [MTL4CommitOptions new];
    hs_metal_frame_slot *submitted_slot = &slot;
    [commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
      @autoreleasepool {
        submitted_slot->finish(feedback);
      }
    }];

    slot.submit();
    reservation.disarm();

    std::array<id<MTL4CommandBuffer>, 1> command_buffers{command_buffer};
    [context->commandQueue waitForDrawable:drawable];
    [context->commandQueue commit:command_buffers.data()
                            count:command_buffers.size()
                          options:commit_options];
    [context->commandQueue signalDrawable:drawable];
    [drawable present];
    return 1;
  }
}
