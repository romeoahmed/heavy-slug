// Metal 4 renderer bridge exposed as a small C ABI for Zig.

#include "bridge.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <expected>
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

using U8View = std::span<const char8_t>;
using U8Buffer = std::span<char8_t>;

struct Failure final {
  __strong NSString *message = nil;
};

template <typename T> using Result = std::expected<T, Failure>;
using Status = std::expected<void, Failure>;

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

template <std::size_t N>
[[nodiscard]] constexpr U8View u8Span(const char8_t (&text)[N]) noexcept {
  static_assert(N > 0);
  return U8View{text, N - 1};
}

[[nodiscard]] constexpr const char *charData(U8View text) noexcept {
  return reinterpret_cast<const char *>(text.data());
}

[[nodiscard]] constexpr U8View sourceView(hs_metal_u8_view view) noexcept {
  if (view.data == nullptr || view.size == 0) {
    return {};
  }
  return U8View{view.data, view.size};
}

[[nodiscard]] constexpr U8Buffer errorBuffer(hs_metal_u8_buffer buffer) noexcept {
  if (buffer.data == nullptr || buffer.size == 0) {
    return {};
  }
  return U8Buffer{buffer.data, buffer.size};
}

[[nodiscard]] NSString *makeNSString(U8View text) {
  if (text.empty()) {
    return @"";
  }
  return [[NSString alloc] initWithBytes:charData(text)
                                  length:text.size()
                                encoding:NSUTF8StringEncoding];
}

[[nodiscard]] std::unexpected<Failure> fail(NSString *message) {
  if (!message) {
    message = @"unknown Metal error";
  }
  return std::unexpected<Failure>{Failure{message}};
}

[[nodiscard]] std::unexpected<Failure> fail(U8View message) {
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
  explicit ErrorBuffer(hs_metal_u8_buffer buffer) noexcept
      : storage_(errorBuffer(buffer)) {
    if (!storage_.empty()) {
      storage_.front() = static_cast<char8_t>(0);
    }
  }

  void write(const Failure &failure) const {
    if (storage_.empty()) {
      return;
    }

    NSString *message = failure.message;
    if (!message) {
      message = @"unknown Metal error";
    }
    const char *bytes = [message UTF8String];
    if (!bytes) {
      bytes = "unknown Metal error";
    }
    writeCString(bytes);
  }

private:
  void writeCString(const char *bytes) const {
    if (!bytes || storage_.empty()) {
      return;
    }

    const std::size_t writable = storage_.size() - 1;
    std::size_t index = 0;
    while (index < writable && bytes[index] != '\0') {
      storage_[index] = static_cast<char8_t>(
          static_cast<unsigned char>(bytes[index]));
      index += 1;
    }
    storage_[index] = static_cast<char8_t>(0);
  }

  U8Buffer storage_;
};

template <typename T, typename... Args>
[[nodiscard]] std::unique_ptr<T> makeOwned(Args &&...args) {
  return std::unique_ptr<T>(
      new (std::nothrow) T(std::forward<Args>(args)...));
}

[[nodiscard]] hs_metal_status complete(Status result,
                                       hs_metal_u8_buffer error_buffer) {
  ErrorBuffer error(error_buffer);
  if (result) {
    return HS_METAL_STATUS_OK;
  }
  error.write(result.error());
  return HS_METAL_STATUS_ERROR;
}

struct ShaderSource final {
  U8View text;
  U8View label;
};

[[nodiscard]] Result<ShaderSource>
loadShaderSource(hs_metal_u8_view source, U8View label) {
  NSString *label_string = makeNSString(label);
  if (!label_string) {
    label_string = @"shader";
  }

  if (source.data == nullptr) {
    return fail([NSString stringWithFormat:@"%@ source pointer is null",
                                           label_string]);
  }
  if (source.size == 0) {
    return fail([NSString stringWithFormat:@"%@ source is empty", label_string]);
  }
  return ShaderSource{sourceView(source), label};
}

struct HostObjects final {
  __strong id<MTLDevice> device = nil;
  __strong id<MTL4CommandQueue> commandQueue = nil;
  __strong CAMetalLayer *layer = nil;
  __strong id<MTLResidencySet> drawableResidency = nil;
  MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
};

[[nodiscard]] Result<HostObjects> loadHostObjects(hs_metal_host host) {
  id<MTLDevice> device = (__bridge id<MTLDevice>)host.device;
  if (!device) {
    return fail(u8Span(u8"Metal context creation received a nil MTLDevice"));
  }
  if (![device supportsFamily:MTLGPUFamilyMetal4]) {
    return fail(u8Span(u8"heavy-slug metal4 requires a Metal 4 family GPU"));
  }

  id<MTL4CommandQueue> command_queue =
      (__bridge id<MTL4CommandQueue>)host.command_queue;
  if (!command_queue) {
    return fail(u8Span(u8"Metal context creation received a nil MTL4CommandQueue"));
  }
  if (command_queue.device != device) {
    return fail(
        u8Span(u8"Metal context received a command queue from a different device"));
  }

  CAMetalLayer *layer = (__bridge CAMetalLayer *)host.layer;
  if (!layer) {
    return fail(u8Span(u8"Metal context creation received a nil CAMetalLayer"));
  }
  if (layer.device != device) {
    return fail(
        u8Span(u8"Metal context received a CAMetalLayer from a different device"));
  }
  if (layer.pixelFormat == MTLPixelFormatInvalid) {
    return fail(
        u8Span(u8"Metal context received a CAMetalLayer with an invalid pixelFormat"));
  }
  if (!layer.residencySet) {
    return fail(
        u8Span(u8"Metal context received a CAMetalLayer without a residency set"));
  }

  return HostObjects{
      .device = device,
      .commandQueue = command_queue,
      .layer = layer,
      .drawableResidency = layer.residencySet,
      .colorFormat = layer.pixelFormat,
  };
}

[[nodiscard]] Result<id<MTL4Compiler>> makeCompiler(id<MTLDevice> device) {
  MTL4CompilerDescriptor *descriptor = [MTL4CompilerDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4CompilerDescriptor"));
  }
  descriptor.label = @"heavy-slug compiler";

  NSError *compiler_error = nil;
  id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:descriptor
                                                          error:&compiler_error];
  if (!compiler) {
    return fail(@"failed to create Metal compiler", compiler_error);
  }
  return compiler;
}

[[nodiscard]] Result<id<MTLLibrary>>
makeLibrary(id<MTL4Compiler> compiler, const ShaderSource &source) {
  NSString *source_string = makeNSString(source.text);
  NSString *label = makeNSString(source.label);
  if (!label) {
    label = @"shader";
  }
  if (!source_string) {
    return fail([NSString stringWithFormat:@"failed to decode %@ as UTF-8",
                                           label]);
  }

  MTLCompileOptions *options = [MTLCompileOptions new];
  if (!options) {
    return fail(u8Span(u8"failed to allocate MTLCompileOptions"));
  }
  options.languageVersion = MTLLanguageVersion4_0;

  MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4LibraryDescriptor"));
  }
  descriptor.name = label;
  descriptor.source = source_string;
  descriptor.options = options;

  NSError *library_error = nil;
  id<MTLLibrary> library = [compiler newLibraryWithDescriptor:descriptor
                                                        error:&library_error];
  if (!library) {
    return fail([NSString stringWithFormat:@"failed to compile %@", label],
                library_error);
  }
  return library;
}

[[nodiscard]] Result<MTL4LibraryFunctionDescriptor *>
makeFunctionDescriptor(id<MTLLibrary> library, NSString *name) {
  MTL4LibraryFunctionDescriptor *descriptor =
      [MTL4LibraryFunctionDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4LibraryFunctionDescriptor"));
  }
  descriptor.library = library;
  descriptor.name = name;
  return descriptor;
}

[[nodiscard]] Result<id<MTLRenderPipelineState>>
makePipeline(id<MTL4Compiler> compiler, MTLPixelFormat color_format,
             const ShaderSource &mesh_source,
             const ShaderSource &fragment_source) {
  auto mesh_library = makeLibrary(compiler, mesh_source);
  if (!mesh_library) {
    return std::unexpected<Failure>{mesh_library.error()};
  }

  auto fragment_library = makeLibrary(compiler, fragment_source);
  if (!fragment_library) {
    return std::unexpected<Failure>{fragment_library.error()};
  }

  auto mesh_function = makeFunctionDescriptor(*mesh_library, @"meshMain");
  if (!mesh_function) {
    return std::unexpected<Failure>{mesh_function.error()};
  }
  auto fragment_function =
      makeFunctionDescriptor(*fragment_library, @"fragmentMain");
  if (!fragment_function) {
    return std::unexpected<Failure>{fragment_function.error()};
  }

  MTL4MeshRenderPipelineDescriptor *descriptor =
      [MTL4MeshRenderPipelineDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4MeshRenderPipelineDescriptor"));
  }
  descriptor.label = @"heavy-slug mesh pipeline";
  descriptor.objectFunctionDescriptor = nil;
  descriptor.meshFunctionDescriptor = *mesh_function;
  descriptor.fragmentFunctionDescriptor = *fragment_function;
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
  if (!attachment) {
    return fail(u8Span(u8"Metal pipeline descriptor returned a nil color attachment"));
  }
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
    return fail(@"failed to create Metal mesh render pipeline", pipeline_error);
  }
  return pipeline;
}

[[nodiscard]] Result<id<MTLResidencySet>>
makeResidencySet(id<MTLDevice> device) {
  MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTLResidencySetDescriptor"));
  }
  descriptor.label = @"heavy-slug resources";
  descriptor.initialCapacity = 8;

  NSError *residency_error = nil;
  id<MTLResidencySet> residency =
      [device newResidencySetWithDescriptor:descriptor error:&residency_error];
  if (!residency) {
    return fail(@"failed to create Metal residency set", residency_error);
  }
  return residency;
}

[[nodiscard]] Result<id<MTL4ArgumentTable>>
makeArgumentTable(id<MTLDevice> device, std::size_t slot_index) {
  MTL4ArgumentTableDescriptor *descriptor = [MTL4ArgumentTableDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4ArgumentTableDescriptor"));
  }
  descriptor.maxBufferBindCount = kBufferBindCount;
  descriptor.maxTextureBindCount = 0;
  descriptor.maxSamplerStateBindCount = 0;
  descriptor.initializeBindings = YES;
  descriptor.supportAttributeStrides = NO;
  descriptor.label =
      [NSString stringWithFormat:@"heavy-slug arguments %zu", slot_index];

  NSError *argument_error = nil;
  id<MTL4ArgumentTable> table =
      [device newArgumentTableWithDescriptor:descriptor error:&argument_error];
  if (!table) {
    return fail(@"failed to create Metal argument table", argument_error);
  }
  return table;
}

[[nodiscard]] Result<id<MTL4CommandAllocator>>
makeCommandAllocator(id<MTLDevice> device, std::size_t slot_index) {
  MTL4CommandAllocatorDescriptor *descriptor =
      [MTL4CommandAllocatorDescriptor new];
  if (!descriptor) {
    return fail(u8Span(u8"failed to allocate MTL4CommandAllocatorDescriptor"));
  }
  descriptor.label =
      [NSString stringWithFormat:@"heavy-slug command allocator %zu",
                                 slot_index];

  NSError *allocator_error = nil;
  id<MTL4CommandAllocator> allocator =
      [device newCommandAllocatorWithDescriptor:descriptor
                                          error:&allocator_error];
  if (!allocator) {
    return fail(@"failed to create Metal command allocator", allocator_error);
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

  [[nodiscard]] Status init(id<MTLDevice> device, std::size_t index) {
    semaphore = dispatch_semaphore_create(1);
    if (!semaphore) {
      return fail(u8Span(u8"dispatch_semaphore_create returned nil"));
    }

    auto new_allocator = makeCommandAllocator(device, index);
    if (!new_allocator) {
      return std::unexpected<Failure>{new_allocator.error()};
    }
    allocator = *new_allocator;

    auto new_arguments = makeArgumentTable(device, index);
    if (!new_arguments) {
      return std::unexpected<Failure>{new_arguments.error()};
    }
    arguments = *new_arguments;
    return {};
  }

  [[nodiscard]] Status reserve() {
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (failed) {
      NSString *message = failureMessage;
      failed = false;
      failureMessage = nil;
      dispatch_semaphore_signal(semaphore);
      return fail(message);
    }

    [allocator reset];
    reserved = true;
    return {};
  }

  void releaseReservation() {
    if (!reserved) {
      return;
    }
    reserved = false;
    dispatch_semaphore_signal(semaphore);
  }

  void markSubmitted() {
    reserved = false;
    failed = false;
    failureMessage = nil;
  }

  void finish(id<MTL4CommitFeedback> feedback) {
    NSError *feedback_error = feedback ? feedback.error : nil;
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
  __strong id<MTLResidencySet> residency = nil;
  std::size_t size = 0;

  hs_metal_buffer(hs_metal_context *context, id<MTLBuffer> buffer_,
                  std::size_t size_) noexcept
      : owner(context), buffer(buffer_),
        residency(context ? context->resourceResidency : nil), size(size_) {}

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
         buffer->buffer != nil && buffer->size > 0;
}

void bindBuffer(id<MTL4ArgumentTable> table, hs_metal_buffer *buffer,
                BufferSlot slot) {
  [table setAddress:buffer->buffer.gpuAddress atIndex:tableIndex(slot)];
}

[[nodiscard]] Status bindFrameParams(id<MTL4ArgumentTable> table,
                                     hs_metal_buffer *frame_params,
                                     std::uint32_t chunk_index,
                                     std::size_t stride) {
  if (stride == 0) {
    return fail(u8Span(u8"Metal draw received a zero frame parameter stride"));
  }
  if (static_cast<std::size_t>(chunk_index) >
      std::numeric_limits<std::size_t>::max() / stride) {
    return fail(u8Span(u8"Metal frame parameter byte offset overflowed"));
  }

  const std::size_t offset_bytes =
      static_cast<std::size_t>(chunk_index) * stride;
  if (offset_bytes > frame_params->size ||
      stride > frame_params->size - offset_bytes) {
    return fail(u8Span(u8"Metal frame parameter chunk exceeds its buffer"));
  }

  const auto offset = static_cast<MTLGPUAddress>(offset_bytes);
  if (static_cast<std::size_t>(offset) != offset_bytes) {
    return fail(u8Span(u8"Metal frame parameter GPU offset overflowed"));
  }
  const MTLGPUAddress base = frame_params->buffer.gpuAddress;
  const MTLGPUAddress address = base + offset;
  if (address < base) {
    return fail(u8Span(u8"Metal frame parameter GPU address overflowed"));
  }
  [table setAddress:address atIndex:tableIndex(BufferSlot::frameParams)];
  return {};
}

[[nodiscard]] Result<MTL4RenderPassDescriptor *>
makeRenderPass(id<CAMetalDrawable> drawable, float clear_r, float clear_g,
               float clear_b, float clear_a) {
  MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
  if (!pass) {
    return fail(u8Span(u8"failed to allocate MTL4RenderPassDescriptor"));
  }
  auto *attachment = pass.colorAttachments[0];
  if (!attachment) {
    return fail(
        u8Span(u8"Metal render pass descriptor returned a nil color attachment"));
  }
  attachment.texture = drawable.texture;
  attachment.loadAction = MTLLoadActionClear;
  attachment.storeAction = MTLStoreActionStore;
  attachment.clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, clear_a);
  return pass;
}

[[nodiscard]] Status validateDrawBuffers(hs_metal_context *context,
                                         hs_metal_buffer *glyphs,
                                         hs_metal_buffer *meshlets,
                                         hs_metal_buffer *frame_params,
                                         hs_metal_buffer *glyph_pool,
                                         hs_metal_buffer *shader_stats) {
  if (!bufferBelongsTo(context, glyphs) || !bufferBelongsTo(context, meshlets) ||
      !bufferBelongsTo(context, frame_params) ||
      !bufferBelongsTo(context, glyph_pool)) {
    return fail(u8Span(u8"Metal draw received a null or foreign buffer handle"));
  }
#if HEAVY_SLUG_SHADER_STATS
  if (!bufferBelongsTo(context, shader_stats)) {
    return fail(u8Span(u8"Metal draw requires a shader-stats buffer from this context"));
  }
#else
  (void)shader_stats;
#endif
  return {};
}

void waitForSubmittedWork(hs_metal_context *context) {
  if (!context) {
    return;
  }
  for (hs_metal_frame_slot &slot : context->slots) {
    if (!slot.semaphore) {
      continue;
    }
    dispatch_semaphore_wait(slot.semaphore, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(slot.semaphore);
  }
}

[[nodiscard]] Result<std::unique_ptr<hs_metal_context>>
makeContext(hs_metal_host host, hs_metal_u8_view mesh_source,
            hs_metal_u8_view fragment_source) {
  auto host_objects = loadHostObjects(host);
  if (!host_objects) {
    return std::unexpected<Failure>{host_objects.error()};
  }

  auto mesh_text = loadShaderSource(mesh_source, u8Span(u8"mesh shader"));
  if (!mesh_text) {
    return std::unexpected<Failure>{mesh_text.error()};
  }

  auto fragment_text =
      loadShaderSource(fragment_source, u8Span(u8"fragment shader"));
  if (!fragment_text) {
    return std::unexpected<Failure>{fragment_text.error()};
  }

  auto compiler = makeCompiler(host_objects->device);
  if (!compiler) {
    return std::unexpected<Failure>{compiler.error()};
  }

  auto pipeline = makePipeline(*compiler, host_objects->colorFormat, *mesh_text,
                               *fragment_text);
  if (!pipeline) {
    return std::unexpected<Failure>{pipeline.error()};
  }

  auto resource_residency = makeResidencySet(host_objects->device);
  if (!resource_residency) {
    return std::unexpected<Failure>{resource_residency.error()};
  }

  auto context =
      makeOwned<hs_metal_context>(*host_objects, *pipeline, *resource_residency);
  if (!context) {
    return fail(u8Span(u8"failed to allocate Metal context"));
  }

  for (std::size_t index = 0; index < context->slots.size(); index += 1) {
    auto slot_status = context->slots[index].init(host_objects->device, index);
    if (!slot_status) {
      return std::unexpected<Failure>{slot_status.error()};
    }
  }

  return std::move(context);
}

[[nodiscard]] Status waitFrameSlot(hs_metal_context *context,
                                   std::uint32_t slot_index) {
  if (!context || !validSlotIndex(slot_index)) {
    return fail(u8Span(u8"invalid Metal frame slot"));
  }
  return slotAt(*context, slot_index).reserve();
}

[[nodiscard]] Status draw(hs_metal_context *context, std::uint32_t width,
                          std::uint32_t height, float clear_r, float clear_g,
                          float clear_b, float clear_a, hs_metal_buffer *glyphs,
                          hs_metal_buffer *meshlets,
                          hs_metal_buffer *frame_params,
                          std::size_t frame_params_stride,
                          hs_metal_buffer *glyph_pool,
                          hs_metal_buffer *shader_stats,
                          std::uint32_t workgroup_count,
                          std::uint32_t slot_index) {
  if (!context) {
    return fail(u8Span(u8"Metal draw received a null context"));
  }

  auto buffer_status = validateDrawBuffers(context, glyphs, meshlets,
                                           frame_params, glyph_pool,
                                           shader_stats);
  if (!buffer_status) {
    return std::unexpected<Failure>{buffer_status.error()};
  }
  if (!validSlotIndex(slot_index)) {
    return fail(u8Span(u8"invalid Metal frame slot"));
  }

  hs_metal_frame_slot &slot = slotAt(*context, slot_index);
  if (!slot.reserved) {
    return fail(u8Span(u8"Metal draw used an unreserved frame slot"));
  }
  SlotReservation reservation(slot);

  if (workgroup_count == 0) {
    return {};
  }
  if (width == 0 || height == 0) {
    return fail(u8Span(u8"Metal draw requires a nonzero viewport"));
  }
  if (frame_params_stride == 0) {
    return fail(u8Span(u8"Metal draw received a zero frame parameter stride"));
  }
  if (context->layer.pixelFormat != context->colorFormat) {
    return fail(
        u8Span(u8"CAMetalLayer pixelFormat changed after Metal pipeline creation"));
  }

  context->layer.drawableSize =
      CGSizeMake(static_cast<CGFloat>(width), static_cast<CGFloat>(height));
  id<CAMetalDrawable> drawable = [context->layer nextDrawable];
  if (!drawable) {
    return fail(u8Span(u8"CAMetalLayer nextDrawable returned nil"));
  }

  auto pass = makeRenderPass(drawable, clear_r, clear_g, clear_b, clear_a);
  if (!pass) {
    return std::unexpected<Failure>{pass.error()};
  }

  id<MTL4CommandBuffer> command_buffer = [context->device newCommandBuffer];
  if (!command_buffer) {
    return fail(u8Span(u8"newCommandBuffer returned nil"));
  }
  command_buffer.label = @"heavy-slug draw";
  [command_buffer beginCommandBufferWithAllocator:slot.allocator];
  [command_buffer useResidencySet:context->resourceResidency];
  [command_buffer useResidencySet:context->drawableResidency];

  id<MTL4RenderCommandEncoder> encoder =
      [command_buffer renderCommandEncoderWithDescriptor:*pass];
  if (!encoder) {
    [command_buffer endCommandBuffer];
    return fail(u8Span(u8"renderCommandEncoderWithDescriptor returned nil"));
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

    auto bind_status =
        bindFrameParams(slot.arguments, frame_params, chunk_index,
                        frame_params_stride);
    if (!bind_status) {
      [encoder endEncoding];
      [command_buffer endCommandBuffer];
      return std::unexpected<Failure>{bind_status.error()};
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
  if (!commit_options) {
    return fail(u8Span(u8"failed to allocate MTL4CommitOptions"));
  }

  hs_metal_frame_slot *submitted_slot = &slot;
  [commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
    @autoreleasepool {
      submitted_slot->finish(feedback);
    }
  }];

  slot.markSubmitted();
  reservation.disarm();

  std::array<id<MTL4CommandBuffer>, 1> command_buffers{command_buffer};
  [context->commandQueue waitForDrawable:drawable];
  [context->commandQueue commit:command_buffers.data()
                          count:static_cast<NSUInteger>(command_buffers.size())
                        options:commit_options];
  [context->commandQueue signalDrawable:drawable];
  [drawable present];
  return {};
}

} // namespace

hs_metal_status
hs_metal_context_create(hs_metal_context **out_context, hs_metal_host host,
                        hs_metal_u8_view mesh_source,
                        hs_metal_u8_view fragment_source,
                        hs_metal_u8_buffer error_buffer) {
  @autoreleasepool {
    ErrorBuffer error(error_buffer);
    if (!out_context) {
      error.write(Failure{@"Metal context create received a nil out parameter"});
      return HS_METAL_STATUS_ERROR;
    }
    *out_context = nullptr;

    auto context = makeContext(host, mesh_source, fragment_source);
    if (!context) {
      error.write(context.error());
      return HS_METAL_STATUS_ERROR;
    }
    *out_context = context->release();
    return HS_METAL_STATUS_OK;
  }
}

void hs_metal_context_destroy(hs_metal_context *context) {
  if (!context) {
    return;
  }
  std::unique_ptr<hs_metal_context> owned(context);
  waitForSubmittedWork(owned.get());
}

hs_metal_status
hs_metal_context_wait_frame_slot(hs_metal_context *context,
                                 uint32_t slot_index,
                                 hs_metal_u8_buffer error_buffer) {
  return complete(waitFrameSlot(context, slot_index), error_buffer);
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

hs_metal_status hs_metal_buffer_create(hs_metal_buffer **out_buffer,
                                       hs_metal_context *context, size_t size,
                                       hs_metal_u8_buffer error_buffer) {
  @autoreleasepool {
    ErrorBuffer error(error_buffer);
    if (!out_buffer) {
      error.write(Failure{@"Metal buffer create received a nil out parameter"});
      return HS_METAL_STATUS_ERROR;
    }
    *out_buffer = nullptr;
    if (!context) {
      error.write(Failure{@"Metal buffer create received a null context"});
      return HS_METAL_STATUS_ERROR;
    }
    if (size == 0) {
      error.write(Failure{@"Metal buffer create received a zero size"});
      return HS_METAL_STATUS_ERROR;
    }
    if (size > static_cast<std::size_t>(std::numeric_limits<NSUInteger>::max())) {
      error.write(Failure{@"Metal buffer size exceeds NSUInteger"});
      return HS_METAL_STATUS_ERROR;
    }

    id<MTLBuffer> buffer =
        [context->device newBufferWithLength:static_cast<NSUInteger>(size)
                                     options:MTLResourceStorageModeShared];
    if (!buffer) {
      error.write(Failure{@"newBufferWithLength returned nil"});
      return HS_METAL_STATUS_ERROR;
    }
    buffer.label = @"heavy-slug buffer";

    auto wrapper = makeOwned<hs_metal_buffer>(context, buffer, size);
    if (!wrapper) {
      error.write(Failure{@"failed to allocate Metal buffer handle"});
      return HS_METAL_STATUS_ERROR;
    }

    [context->resourceResidency addAllocation:buffer];
    [context->resourceResidency commit];
    *out_buffer = wrapper.release();
    return HS_METAL_STATUS_OK;
  }
}

void hs_metal_buffer_destroy(hs_metal_buffer *buffer) {
  std::unique_ptr<hs_metal_buffer> owned(buffer);
  if (owned && owned->residency && owned->buffer) {
    [owned->residency removeAllocation:owned->buffer];
    [owned->residency commit];
  }
}

void *hs_metal_buffer_contents(hs_metal_buffer *buffer) {
  if (!buffer || !buffer->buffer) {
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

hs_metal_status hs_metal_context_draw(
    hs_metal_context *context, uint32_t width, uint32_t height, float clear_r,
    float clear_g, float clear_b, float clear_a, hs_metal_buffer *glyphs,
    hs_metal_buffer *meshlets, hs_metal_buffer *frame_params,
    size_t frame_params_stride, hs_metal_buffer *glyph_pool,
    hs_metal_buffer *shader_stats, uint32_t workgroup_count,
    uint32_t slot_index, hs_metal_u8_buffer error_buffer) {
  @autoreleasepool {
    return complete(draw(context, width, height, clear_r, clear_g, clear_b,
                         clear_a, glyphs, meshlets, frame_params,
                         frame_params_stride, glyph_pool, shader_stats,
                         workgroup_count, slot_index),
                    error_buffer);
  }
}
