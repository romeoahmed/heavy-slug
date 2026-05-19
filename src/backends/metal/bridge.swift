// Metal 4 renderer bridge exposed as Swift 6.3 @c functions for Zig.

import Dispatch
import Foundation
import Metal
import QuartzCore

private let statusOK: Int32 = 0
private let statusError: Int32 = 1

private let frameSlotCount = 3
private let bufferGlyphPool: UInt32 = 0
private let bufferGlyphs: UInt32 = 1
private let bufferMeshlets: UInt32 = 2
private let bufferShaderStats: UInt32 = 3
#if HEAVY_SLUG_SHADER_STATS
  private let bufferFrameParams: UInt32 = 4
  private let bufferBindCount = 5
#else
  private let bufferFrameParams: UInt32 = 3
  private let bufferBindCount = 4
#endif
private let objectThreadgroupSize = 0
private let meshThreadgroupSize = 32
private let maxMeshThreadgroupsPerDraw: UInt32 = 1024
private let boundRenderStages: MTLRenderStages = [.mesh, .fragment]

private struct BridgeFailure: Error, CustomStringConvertible {
  let message: String

  var description: String {
    message
  }
}

private struct ErrorSink {
  let data: UnsafeMutablePointer<UInt8>?
  let size: UInt

  init(_ data: UnsafeMutablePointer<UInt8>?, _ size: UInt) {
    self.data = data
    self.size = size
    if size > 0 {
      data?.pointee = 0
    }
  }

  func write(_ error: Error) {
    write(message(for: error))
  }

  func write(_ message: String) {
    guard let data, size > 0 else {
      return
    }

    let capacity = size > UInt(Int.max) ? Int.max : Int(size)
    guard capacity > 0 else {
      return
    }

    let bytes = Array(message.utf8)
    let count = min(bytes.count, capacity - 1)
    if count > 0 {
      data.update(from: bytes, count: count)
    }
    data.advanced(by: count).pointee = 0
  }
}

private func message(for error: Error) -> String {
  if let failure = error as? BridgeFailure {
    return failure.message
  }

  let nsError = error as NSError
  if !nsError.localizedDescription.isEmpty {
    return nsError.localizedDescription
  }

  return String(describing: error)
}

private func fail(_ message: String) -> BridgeFailure {
  BridgeFailure(message: message)
}

private func checkedInt(_ value: UInt, _ label: String) throws -> Int {
  guard value <= UInt(Int.max) else {
    throw fail("\(label) exceeds Int.max")
  }
  return Int(value)
}

private func shaderSource(_ data: UnsafePointer<UInt8>?, _ size: UInt, label: String) throws
  -> String
{
  guard let data else {
    throw fail("\(label) source pointer is null")
  }
  guard size > 0 else {
    throw fail("\(label) source is empty")
  }

  let count = try checkedInt(size, "\(label) source size")
  let bytes = UnsafeBufferPointer(start: data, count: count)
  guard let source = String(bytes: bytes, encoding: .utf8) else {
    throw fail("failed to decode \(label) source as UTF-8")
  }
  return source
}

private func borrowedDevice(_ pointer: UnsafeMutableRawPointer?) throws -> MTLDevice {
  guard let pointer else {
    throw fail("Metal context creation received a nil MTLDevice")
  }

  let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  guard let device = object as? MTLDevice else {
    throw fail("Metal context creation received a non-MTLDevice object")
  }
  guard device.supportsFamily(.metal4) else {
    throw fail("heavy-slug metal4 requires a Metal 4 family GPU")
  }
  return device
}

private func borrowedCommandQueue(
  _ pointer: UnsafeMutableRawPointer?,
  device: MTLDevice
) throws -> MTL4CommandQueue {
  guard let pointer else {
    throw fail("Metal context creation received a nil MTL4CommandQueue")
  }

  let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  guard let queue = object as? MTL4CommandQueue else {
    throw fail("Metal context creation received a non-MTL4CommandQueue object")
  }
  guard (queue.device as AnyObject) === (device as AnyObject) else {
    throw fail("Metal context received a command queue from a different device")
  }
  return queue
}

private func borrowedLayer(
  _ pointer: UnsafeMutableRawPointer?,
  device: MTLDevice
) throws -> CAMetalLayer {
  guard let pointer else {
    throw fail("Metal context creation received a nil CAMetalLayer")
  }

  let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  guard let layer = object as? CAMetalLayer else {
    throw fail("Metal context creation received a non-CAMetalLayer object")
  }
  guard let layerDevice = layer.device, (layerDevice as AnyObject) === (device as AnyObject) else {
    throw fail("Metal context received a CAMetalLayer from a different device")
  }
  guard layer.pixelFormat != .invalid else {
    throw fail("Metal context received a CAMetalLayer with an invalid pixelFormat")
  }
  return layer
}

private final class MetalFrameSlot: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 1)
  let allocator: MTL4CommandAllocator
  let arguments: MTL4ArgumentTable
  var reserved = false
  private var failed = false
  private var failureMessage: String?

  init(device: MTLDevice, index: Int) throws {
    let allocatorDescriptor = MTL4CommandAllocatorDescriptor()
    allocatorDescriptor.label = "heavy-slug command allocator \(index)"
    allocator = try device.makeCommandAllocator(descriptor: allocatorDescriptor)

    let argumentDescriptor = MTL4ArgumentTableDescriptor()
    argumentDescriptor.maxBufferBindCount = bufferBindCount
    argumentDescriptor.maxTextureBindCount = 0
    argumentDescriptor.maxSamplerStateBindCount = 0
    argumentDescriptor.initializeBindings = true
    argumentDescriptor.supportAttributeStrides = false
    argumentDescriptor.label = "heavy-slug arguments \(index)"
    arguments = try device.makeArgumentTable(descriptor: argumentDescriptor)
  }

  func reserve() throws {
    semaphore.wait()
    if failed {
      let message = failureMessage ?? "unknown Metal command-buffer failure"
      failed = false
      failureMessage = nil
      semaphore.signal()
      throw fail(message)
    }

    allocator.reset()
    reserved = true
  }

  func releaseReservation() {
    guard reserved else {
      return
    }
    reserved = false
    semaphore.signal()
  }

  func markSubmitted() {
    reserved = false
    failed = false
    failureMessage = nil
  }

  func finish(_ feedback: MTL4CommitFeedback?) {
    if let error = feedback?.error {
      failed = true
      failureMessage = error.localizedDescription
    }
    semaphore.signal()
  }

  func waitIdle() {
    semaphore.wait()
    semaphore.signal()
  }
}

private final class MetalContext {
  let device: MTLDevice
  let commandQueue: MTL4CommandQueue
  let layer: CAMetalLayer
  let pipeline: MTLRenderPipelineState
  let resourceResidency: MTLResidencySet
  let drawableResidency: MTLResidencySet
  let colorFormat: MTLPixelFormat
  let slots: [MetalFrameSlot]

  init(
    devicePointer: UnsafeMutableRawPointer?,
    commandQueuePointer: UnsafeMutableRawPointer?,
    layerPointer: UnsafeMutableRawPointer?,
    meshSource: String,
    fragmentSource: String
  ) throws {
    let device = try borrowedDevice(devicePointer)
    let commandQueue = try borrowedCommandQueue(commandQueuePointer, device: device)
    let layer = try borrowedLayer(layerPointer, device: device)
    let drawableResidency = layer.residencySet

    let compilerDescriptor = MTL4CompilerDescriptor()
    compilerDescriptor.label = "heavy-slug compiler"
    let compiler = try device.makeCompiler(descriptor: compilerDescriptor)
    let pipeline = try Self.makePipeline(
      compiler: compiler,
      colorFormat: layer.pixelFormat,
      meshSource: meshSource,
      fragmentSource: fragmentSource
    )

    let residencyDescriptor = MTLResidencySetDescriptor()
    residencyDescriptor.label = "heavy-slug resources"
    residencyDescriptor.initialCapacity = 8
    let resourceResidency = try device.makeResidencySet(descriptor: residencyDescriptor)

    var slots: [MetalFrameSlot] = []
    slots.reserveCapacity(frameSlotCount)
    for index in 0..<frameSlotCount {
      slots.append(try MetalFrameSlot(device: device, index: index))
    }

    self.device = device
    self.commandQueue = commandQueue
    self.layer = layer
    self.pipeline = pipeline
    self.resourceResidency = resourceResidency
    self.drawableResidency = drawableResidency
    self.colorFormat = layer.pixelFormat
    self.slots = slots
  }

  private static func makeLibrary(
    compiler: MTL4Compiler,
    source: String,
    label: String
  ) throws -> MTLLibrary {
    let options = MTLCompileOptions()
    options.languageVersion = .version4_0

    let descriptor = MTL4LibraryDescriptor()
    descriptor.name = label
    descriptor.source = source
    descriptor.options = options
    return try compiler.makeLibrary(descriptor: descriptor)
  }

  private static func functionDescriptor(library: MTLLibrary, name: String)
    -> MTL4LibraryFunctionDescriptor
  {
    let descriptor = MTL4LibraryFunctionDescriptor()
    descriptor.library = library
    descriptor.name = name
    return descriptor
  }

  private static func makePipeline(
    compiler: MTL4Compiler,
    colorFormat: MTLPixelFormat,
    meshSource: String,
    fragmentSource: String
  ) throws -> MTLRenderPipelineState {
    let meshLibrary = try makeLibrary(compiler: compiler, source: meshSource, label: "mesh shader")
    let fragmentLibrary = try makeLibrary(
      compiler: compiler, source: fragmentSource, label: "fragment shader")

    let descriptor = MTL4MeshRenderPipelineDescriptor()
    descriptor.label = "heavy-slug mesh pipeline"
    descriptor.objectFunctionDescriptor = nil
    descriptor.meshFunctionDescriptor = functionDescriptor(library: meshLibrary, name: "meshMain")
    descriptor.fragmentFunctionDescriptor = functionDescriptor(
      library: fragmentLibrary, name: "fragmentMain")
    descriptor.maxTotalThreadsPerObjectThreadgroup = objectThreadgroupSize
    descriptor.maxTotalThreadsPerMeshThreadgroup = meshThreadgroupSize
    descriptor.requiredThreadsPerObjectThreadgroup = MTLSize(width: 0, height: 0, depth: 0)
    descriptor.requiredThreadsPerMeshThreadgroup = MTLSize(
      width: meshThreadgroupSize, height: 1, depth: 1)
    descriptor.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth = false
    descriptor.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth = true
    descriptor.payloadMemoryLength = 0
    descriptor.maxTotalThreadgroupsPerMeshGrid = Int(maxMeshThreadgroupsPerDraw)
    descriptor.rasterSampleCount = 1
    descriptor.alphaToCoverageState = .disabled
    descriptor.alphaToOneState = .disabled
    descriptor.isRasterizationEnabled = true
    descriptor.supportIndirectCommandBuffers = .disabled

    guard let attachment = descriptor.colorAttachments[0] else {
      throw fail("Metal pipeline descriptor returned a nil color attachment")
    }
    attachment.pixelFormat = colorFormat
    attachment.blendingState = .enabled
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

    return try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: nil)
  }

  func waitSubmitted() {
    for slot in slots {
      slot.waitIdle()
    }
  }
}

private final class MetalBuffer {
  let owner: MetalContext
  let buffer: MTLBuffer
  let residency: MTLResidencySet
  let size: UInt

  init(owner: MetalContext, size: UInt) throws {
    guard size > 0 else {
      throw fail("Metal buffer create received a zero size")
    }

    let length = try checkedInt(size, "Metal buffer size")
    guard let buffer = owner.device.makeBuffer(length: length, options: .storageModeShared) else {
      throw fail("newBufferWithLength returned nil")
    }
    buffer.label = "heavy-slug buffer"

    self.owner = owner
    self.buffer = buffer
    self.residency = owner.resourceResidency
    self.size = size

    residency.addAllocations([buffer])
    residency.commit()
  }

  deinit {
    residency.removeAllocations([buffer])
    residency.commit()
  }
}

private func retainedHandle<T: AnyObject>(_ object: T) -> OpaquePointer {
  OpaquePointer(Unmanaged.passRetained(object).toOpaque())
}

private func borrowedContext(_ handle: OpaquePointer?) throws -> MetalContext {
  guard let handle else {
    throw fail("Metal operation received a null context")
  }
  return Unmanaged<MetalContext>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

private func borrowedBuffer(_ handle: OpaquePointer?) -> MetalBuffer? {
  guard let handle else {
    return nil
  }
  return Unmanaged<MetalBuffer>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

private func validSlotIndex(_ index: UInt32) -> Bool {
  Int(index) < frameSlotCount
}

private func slot(context: MetalContext, index: UInt32) -> MetalFrameSlot {
  context.slots[Int(index)]
}

private func requireBuffer(_ handle: OpaquePointer?, owner: MetalContext) throws -> MetalBuffer {
  guard let buffer = borrowedBuffer(handle), buffer.owner === owner, buffer.size > 0 else {
    throw fail("Metal draw received a null or foreign buffer handle")
  }
  return buffer
}

private func bindBuffer(_ table: MTL4ArgumentTable, _ buffer: MetalBuffer, slot: UInt32) {
  table.setAddress(buffer.buffer.gpuAddress, index: Int(slot))
}

private func bindFrameParams(
  table: MTL4ArgumentTable,
  frameParams: MetalBuffer,
  chunkIndex: UInt32,
  stride: UInt
) throws {
  guard stride > 0 else {
    throw fail("Metal draw received a zero frame parameter stride")
  }

  let (offset, overflow) = UInt(chunkIndex).multipliedReportingOverflow(by: stride)
  guard !overflow else {
    throw fail("Metal frame parameter byte offset overflowed")
  }
  guard offset <= frameParams.size, stride <= frameParams.size - offset else {
    throw fail("Metal frame parameter chunk exceeds its buffer")
  }

  let base = frameParams.buffer.gpuAddress
  let address = base + MTLGPUAddress(offset)
  guard address >= base else {
    throw fail("Metal frame parameter GPU address overflowed")
  }
  table.setAddress(address, index: Int(bufferFrameParams))
}

private func makeRenderPass(
  drawable: CAMetalDrawable,
  clearR: Float,
  clearG: Float,
  clearB: Float,
  clearA: Float
) throws -> MTL4RenderPassDescriptor {
  let pass = MTL4RenderPassDescriptor()
  guard let attachment = pass.colorAttachments[0] else {
    throw fail("Metal render pass descriptor returned a nil color attachment")
  }
  attachment.texture = drawable.texture
  attachment.loadAction = .clear
  attachment.storeAction = .store
  attachment.clearColor = MTLClearColor(
    red: Double(clearR),
    green: Double(clearG),
    blue: Double(clearB),
    alpha: Double(clearA)
  )
  return pass
}

private func draw(
  context: MetalContext,
  width: UInt32,
  height: UInt32,
  clearR: Float,
  clearG: Float,
  clearB: Float,
  clearA: Float,
  glyphsHandle: OpaquePointer?,
  meshletsHandle: OpaquePointer?,
  frameParamsHandle: OpaquePointer?,
  frameParamsStride: UInt,
  glyphPoolHandle: OpaquePointer?,
  shaderStatsHandle: OpaquePointer?,
  workgroupCount: UInt32,
  slotIndex: UInt32
) throws {
  guard validSlotIndex(slotIndex) else {
    throw fail("invalid Metal frame slot")
  }
  let frameSlot = slot(context: context, index: slotIndex)
  guard frameSlot.reserved else {
    throw fail("Metal draw used an unreserved frame slot")
  }

  var releaseReservation = true
  defer {
    if releaseReservation {
      frameSlot.releaseReservation()
    }
  }

  guard workgroupCount > 0 else {
    return
  }
  guard width > 0, height > 0 else {
    throw fail("Metal draw requires a nonzero viewport")
  }
  guard frameParamsStride > 0 else {
    throw fail("Metal draw received a zero frame parameter stride")
  }

  let glyphs = try requireBuffer(glyphsHandle, owner: context)
  let meshlets = try requireBuffer(meshletsHandle, owner: context)
  let frameParams = try requireBuffer(frameParamsHandle, owner: context)
  let glyphPool = try requireBuffer(glyphPoolHandle, owner: context)
  #if HEAVY_SLUG_SHADER_STATS
    let shaderStats = try requireBuffer(shaderStatsHandle, owner: context)
  #endif

  guard context.layer.pixelFormat == context.colorFormat else {
    throw fail("CAMetalLayer pixelFormat changed after Metal pipeline creation")
  }

  context.layer.drawableSize = CGSize(width: Int(width), height: Int(height))
  guard let drawable = context.layer.nextDrawable() else {
    throw fail("CAMetalLayer nextDrawable returned nil")
  }

  let commandBuffer = context.device.makeCommandBuffer()
  guard let commandBuffer else {
    throw fail("newCommandBuffer returned nil")
  }
  commandBuffer.label = "heavy-slug draw"
  commandBuffer.beginCommandBuffer(allocator: frameSlot.allocator)
  commandBuffer.useResidencySets([context.resourceResidency, context.drawableResidency])

  let pass = try makeRenderPass(
    drawable: drawable,
    clearR: clearR,
    clearG: clearG,
    clearB: clearB,
    clearA: clearA
  )
  guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
    commandBuffer.endCommandBuffer()
    throw fail("renderCommandEncoderWithDescriptor returned nil")
  }

  bindBuffer(frameSlot.arguments, glyphPool, slot: bufferGlyphPool)
  bindBuffer(frameSlot.arguments, glyphs, slot: bufferGlyphs)
  bindBuffer(frameSlot.arguments, meshlets, slot: bufferMeshlets)
  #if HEAVY_SLUG_SHADER_STATS
    bindBuffer(frameSlot.arguments, shaderStats, slot: bufferShaderStats)
  #endif

  encoder.setViewport(
    MTLViewport(
      originX: 0,
      originY: 0,
      width: Double(width),
      height: Double(height),
      znear: 0,
      zfar: 1
    ))
  encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(width), height: Int(height)))
  encoder.setCullMode(.none)
  encoder.setFrontFacing(.counterClockwise)
  encoder.setTriangleFillMode(.fill)
  encoder.setDepthClipMode(.clip)
  encoder.setDepthStencilState(nil)
  encoder.setRenderPipelineState(context.pipeline)

  var meshletBase: UInt32 = 0
  var chunkIndex: UInt32 = 0
  while meshletBase < workgroupCount {
    let chunkCount = min(workgroupCount - meshletBase, maxMeshThreadgroupsPerDraw)
    do {
      try bindFrameParams(
        table: frameSlot.arguments,
        frameParams: frameParams,
        chunkIndex: chunkIndex,
        stride: frameParamsStride
      )
    } catch {
      encoder.endEncoding()
      commandBuffer.endCommandBuffer()
      throw error
    }

    encoder.setArgumentTable(frameSlot.arguments, stages: boundRenderStages)
    encoder.drawMeshThreadgroups(
      threadgroupsPerGrid: MTLSize(width: Int(chunkCount), height: 1, depth: 1),
      threadsPerObjectThreadgroup: MTLSize(width: 0, height: 0, depth: 0),
      threadsPerMeshThreadgroup: MTLSize(width: meshThreadgroupSize, height: 1, depth: 1)
    )

    meshletBase += chunkCount
    chunkIndex += 1
  }

  encoder.endEncoding()
  commandBuffer.endCommandBuffer()

  let commitOptions = MTL4CommitOptions()
  commitOptions.addFeedbackHandler { feedback in
    frameSlot.finish(feedback)
  }

  frameSlot.markSubmitted()
  releaseReservation = false
  context.commandQueue.waitForDrawable(drawable)
  context.commandQueue.commit([commandBuffer], options: commitOptions)
  context.commandQueue.signalDrawable(drawable)
  drawable.present()
}

@c(hs_metal_context_create)
public func hs_metal_context_create(
  _ outContext: UnsafeMutablePointer<OpaquePointer?>?,
  _ device: UnsafeMutableRawPointer?,
  _ commandQueue: UnsafeMutableRawPointer?,
  _ layer: UnsafeMutableRawPointer?,
  _ meshSourceData: UnsafePointer<UInt8>?,
  _ meshSourceSize: UInt,
  _ fragmentSourceData: UnsafePointer<UInt8>?,
  _ fragmentSourceSize: UInt,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  autoreleasepool {
    let errorSink = ErrorSink(errorData, errorSize)
    guard let outContext else {
      errorSink.write("Metal context create received a nil out parameter")
      return statusError
    }
    outContext.pointee = nil

    do {
      let meshSource = try shaderSource(meshSourceData, meshSourceSize, label: "mesh shader")
      let fragmentSource = try shaderSource(
        fragmentSourceData, fragmentSourceSize, label: "fragment shader")
      let context = try MetalContext(
        devicePointer: device,
        commandQueuePointer: commandQueue,
        layerPointer: layer,
        meshSource: meshSource,
        fragmentSource: fragmentSource
      )
      outContext.pointee = retainedHandle(context)
      return statusOK
    } catch {
      errorSink.write(error)
      return statusError
    }
  }
}

@c(hs_metal_context_destroy)
public func hs_metal_context_destroy(_ contextHandle: OpaquePointer?) {
  guard let contextHandle else {
    return
  }

  autoreleasepool {
    let context = Unmanaged<MetalContext>.fromOpaque(UnsafeRawPointer(contextHandle))
      .takeRetainedValue()
    context.waitSubmitted()
  }
}

@c(hs_metal_context_wait_frame_slot)
public func hs_metal_context_wait_frame_slot(
  _ contextHandle: OpaquePointer?,
  _ slotIndex: UInt32,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  let errorSink = ErrorSink(errorData, errorSize)
  do {
    let context = try borrowedContext(contextHandle)
    guard validSlotIndex(slotIndex) else {
      throw fail("invalid Metal frame slot")
    }
    try slot(context: context, index: slotIndex).reserve()
    return statusOK
  } catch {
    errorSink.write(error)
    return statusError
  }
}

@c(hs_metal_context_release_frame_slot)
public func hs_metal_context_release_frame_slot(
  _ contextHandle: OpaquePointer?, _ slotIndex: UInt32
) {
  guard let context = try? borrowedContext(contextHandle), validSlotIndex(slotIndex) else {
    return
  }
  slot(context: context, index: slotIndex).releaseReservation()
}

@c(hs_metal_context_wait_submitted)
public func hs_metal_context_wait_submitted(_ contextHandle: OpaquePointer?) {
  guard let context = try? borrowedContext(contextHandle) else {
    return
  }
  context.waitSubmitted()
}

@c(hs_metal_buffer_create)
public func hs_metal_buffer_create(
  _ outBuffer: UnsafeMutablePointer<OpaquePointer?>?,
  _ contextHandle: OpaquePointer?,
  _ size: UInt,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  autoreleasepool {
    let errorSink = ErrorSink(errorData, errorSize)
    guard let outBuffer else {
      errorSink.write("Metal buffer create received a nil out parameter")
      return statusError
    }
    outBuffer.pointee = nil

    do {
      let context = try borrowedContext(contextHandle)
      let buffer = try MetalBuffer(owner: context, size: size)
      outBuffer.pointee = retainedHandle(buffer)
      return statusOK
    } catch {
      errorSink.write(error)
      return statusError
    }
  }
}

@c(hs_metal_buffer_destroy)
public func hs_metal_buffer_destroy(_ bufferHandle: OpaquePointer?) {
  guard let bufferHandle else {
    return
  }
  _ = Unmanaged<MetalBuffer>.fromOpaque(UnsafeRawPointer(bufferHandle)).takeRetainedValue()
}

@c(hs_metal_buffer_contents)
public func hs_metal_buffer_contents(_ bufferHandle: OpaquePointer?) -> UnsafeMutableRawPointer? {
  guard let buffer = borrowedBuffer(bufferHandle) else {
    return nil
  }
  return buffer.buffer.contents()
}

@c(hs_metal_context_draw)
public func hs_metal_context_draw(
  _ contextHandle: OpaquePointer?,
  _ width: UInt32,
  _ height: UInt32,
  _ clearR: Float,
  _ clearG: Float,
  _ clearB: Float,
  _ clearA: Float,
  _ glyphs: OpaquePointer?,
  _ meshlets: OpaquePointer?,
  _ frameParams: OpaquePointer?,
  _ frameParamsStride: UInt,
  _ glyphPool: OpaquePointer?,
  _ shaderStats: OpaquePointer?,
  _ workgroupCount: UInt32,
  _ slotIndex: UInt32,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  autoreleasepool {
    let errorSink = ErrorSink(errorData, errorSize)
    do {
      let context = try borrowedContext(contextHandle)
      try draw(
        context: context,
        width: width,
        height: height,
        clearR: clearR,
        clearG: clearG,
        clearB: clearB,
        clearA: clearA,
        glyphsHandle: glyphs,
        meshletsHandle: meshlets,
        frameParamsHandle: frameParams,
        frameParamsStride: frameParamsStride,
        glyphPoolHandle: glyphPool,
        shaderStatsHandle: shaderStats,
        workgroupCount: workgroupCount,
        slotIndex: slotIndex
      )
      return statusOK
    } catch {
      errorSink.write(error)
      return statusError
    }
  }
}
