// Metal 4 renderer bridge exposed as Swift 6.3 @c functions for Zig.

import Dispatch
import Foundation
import Metal
import QuartzCore

private let statusOK: Int32 = 0
private let statusError: Int32 = 1

private let frameSlotCount = 3
private let drawRequestProtocolVersion = protocolVersion(major: 1, minor: 1)
private let drawRequestFlagClearOnly: UInt32 = 1 << 0
private let drawRequestKnownFlags = drawRequestFlagClearOnly
// Buffer-slot constants mirror src/gpu/resource_model.zig::BufferBinding.
// `frameParams` is pinned to slot 4 via an explicit `register(b4)` on the
// Slang push-constant declaration, so the index — and the argument-table
// bind count — are independent of the shader-stats build flag.
private let bufferGlyphPool: UInt32 = 0
private let bufferGlyphs: UInt32 = 1
private let bufferMeshlets: UInt32 = 2
private let bufferShaderStats: UInt32 = 3
private let bufferFrameParams: UInt32 = 4
private let bufferBindCount = 5
private let objectThreadgroupSize = 0
private let meshThreadgroupSize = 32
private let maxMeshThreadgroupsPerDraw: UInt32 = 1024
private let boundRenderStages: MTLRenderStages = [.mesh, .fragment]

private func protocolVersion(major: UInt32, minor: UInt32) -> UInt32 {
  (major << 16) | minor
}

private func protocolVersionDescription(_ version: UInt32) -> String {
  "\(version >> 16).\(version & 0xffff)"
}

private enum DrawRequestLayout {
  static let byteSize = 88
  static let protocolVersion = 0
  static let width = 4
  static let height = 8
  static let slotIndex = 12
  static let workgroupCount = 16
  static let flags = 20
  static let clearR = 24
  static let clearG = 28
  static let clearB = 32
  static let clearA = 36
  static let frameParamsStride = 40
  static let glyphs = 48
  static let meshlets = 56
  static let frameParams = 64
  static let glyphPool = 72
  static let shaderStats = 80
}

private struct DrawRequest {
  let width: UInt32
  let height: UInt32
  let slotIndex: UInt32
  let workgroupCount: UInt32
  let flags: UInt32
  let clearR: Float
  let clearG: Float
  let clearB: Float
  let clearA: Float
  let frameParamsStride: UInt
  let glyphs: OpaquePointer?
  let meshlets: OpaquePointer?
  let frameParams: OpaquePointer?
  let glyphPool: OpaquePointer?
  let shaderStats: OpaquePointer?

  init(data: UnsafeRawPointer?, size: UInt) throws {
    guard MemoryLayout<UInt>.size == 8, MemoryLayout<OpaquePointer?>.size == 8 else {
      throw fail("Metal draw request ABI requires a 64-bit target")
    }
    guard let data else {
      throw fail("Metal draw received a null draw request")
    }
    guard size >= UInt(DrawRequestLayout.byteSize) else {
      throw fail("Metal draw request is smaller than the expected ABI size")
    }

    let protocolVersion = data.load(
      fromByteOffset: DrawRequestLayout.protocolVersion, as: UInt32.self)
    guard protocolVersion == drawRequestProtocolVersion else {
      throw fail(
        "unsupported Metal draw request protocol version \(protocolVersionDescription(protocolVersion))"
      )
    }
    flags = data.load(fromByteOffset: DrawRequestLayout.flags, as: UInt32.self)
    guard (flags & ~drawRequestKnownFlags) == 0 else {
      throw fail("Metal draw request contains unknown flags")
    }

    width = data.load(fromByteOffset: DrawRequestLayout.width, as: UInt32.self)
    height = data.load(fromByteOffset: DrawRequestLayout.height, as: UInt32.self)
    slotIndex = data.load(fromByteOffset: DrawRequestLayout.slotIndex, as: UInt32.self)
    workgroupCount = data.load(fromByteOffset: DrawRequestLayout.workgroupCount, as: UInt32.self)
    clearR = data.load(fromByteOffset: DrawRequestLayout.clearR, as: Float.self)
    clearG = data.load(fromByteOffset: DrawRequestLayout.clearG, as: Float.self)
    clearB = data.load(fromByteOffset: DrawRequestLayout.clearB, as: Float.self)
    clearA = data.load(fromByteOffset: DrawRequestLayout.clearA, as: Float.self)
    frameParamsStride = data.load(
      fromByteOffset: DrawRequestLayout.frameParamsStride, as: UInt.self)
    glyphs = data.load(fromByteOffset: DrawRequestLayout.glyphs, as: OpaquePointer?.self)
    meshlets = data.load(fromByteOffset: DrawRequestLayout.meshlets, as: OpaquePointer?.self)
    frameParams = data.load(fromByteOffset: DrawRequestLayout.frameParams, as: OpaquePointer?.self)
    glyphPool = data.load(fromByteOffset: DrawRequestLayout.glyphPool, as: OpaquePointer?.self)
    shaderStats = data.load(fromByteOffset: DrawRequestLayout.shaderStats, as: OpaquePointer?.self)
  }
}

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

private func libraryData(_ data: UnsafePointer<UInt8>?, _ size: UInt) throws -> DispatchData {
  guard let data else {
    throw fail("Metal library pointer is null")
  }
  guard size > 0 else {
    throw fail("Metal library byte slice is empty")
  }

  let count = try checkedInt(size, "Metal library size")
  // DispatchData copies the bytes, matching the semantics
  // MTLDevice.makeLibrary(data:) expects from a dispatch_data_t input.
  return DispatchData(bytes: UnsafeRawBufferPointer(start: data, count: count))
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
  // `reserved`, `failed`, and `failureMessage` cross threads but rely on the
  // happens-before edge that `semaphore.wait()` and `semaphore.signal()`
  // already establish (Swift Concurrency Manifesto §"Adopting Strict
  // Concurrency Checking"). Mark them `nonisolated(unsafe)` so the
  // `-strict-concurrency=complete` mode under Swift 6 stops flagging them
  // without forcing an unnecessary additional lock.
  nonisolated(unsafe) var reserved = false
  nonisolated(unsafe) private var failed = false
  nonisolated(unsafe) private var failureMessage: String?

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
    library: DispatchData
  ) throws {
    let device = try borrowedDevice(devicePointer)
    let commandQueue = try borrowedCommandQueue(commandQueuePointer, device: device)
    let layer = try borrowedLayer(layerPointer, device: device)
    let drawableResidency = layer.residencySet

    // Build-graph precompiled metallib loaded with MTLDevice.makeLibrary(data:)
    // (Apple, "Retrieve and load a library"). Skips the ~50–150 ms MSL parse
    // that MTL4Compiler.makeLibrary(descriptor:) would perform on every init.
    let mtlLibrary = try device.makeLibrary(data: library as __DispatchData)

    let compilerDescriptor = MTL4CompilerDescriptor()
    compilerDescriptor.label = "heavy-slug compiler"
    let compiler = try device.makeCompiler(descriptor: compilerDescriptor)
    let pipeline = try Self.makePipeline(
      compiler: compiler,
      colorFormat: layer.pixelFormat,
      library: mtlLibrary
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
    library: MTLLibrary
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTL4MeshRenderPipelineDescriptor()
    descriptor.label = "heavy-slug mesh pipeline"
    descriptor.objectFunctionDescriptor = nil
    descriptor.meshFunctionDescriptor = functionDescriptor(library: library, name: "meshMain")
    descriptor.fragmentFunctionDescriptor = functionDescriptor(
      library: library, name: "fragmentMain")
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

private struct DrawResources {
  let glyphs: MetalBuffer
  let meshlets: MetalBuffer
  let frameParams: MetalBuffer
  let glyphPool: MetalBuffer
  #if HEAVY_SLUG_SHADER_STATS
    let shaderStats: MetalBuffer
  #endif
}

private func drawResources(context: MetalContext, request: DrawRequest) throws -> DrawResources {
  #if HEAVY_SLUG_SHADER_STATS
    return try DrawResources(
      glyphs: requireBuffer(request.glyphs, owner: context),
      meshlets: requireBuffer(request.meshlets, owner: context),
      frameParams: requireBuffer(request.frameParams, owner: context),
      glyphPool: requireBuffer(request.glyphPool, owner: context),
      shaderStats: requireBuffer(request.shaderStats, owner: context)
    )
  #else
    return try DrawResources(
      glyphs: requireBuffer(request.glyphs, owner: context),
      meshlets: requireBuffer(request.meshlets, owner: context),
      frameParams: requireBuffer(request.frameParams, owner: context),
      glyphPool: requireBuffer(request.glyphPool, owner: context)
    )
  #endif
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

private func draw(context: MetalContext, request: DrawRequest) throws {
  guard validSlotIndex(request.slotIndex) else {
    throw fail("invalid Metal frame slot")
  }
  let frameSlot = slot(context: context, index: request.slotIndex)
  guard frameSlot.reserved else {
    throw fail("Metal draw used an unreserved frame slot")
  }

  var releaseReservation = true
  defer {
    if releaseReservation {
      frameSlot.releaseReservation()
    }
  }

  guard request.width > 0, request.height > 0 else {
    throw fail("Metal draw requires a nonzero viewport")
  }
  let clearOnly = (request.flags & drawRequestFlagClearOnly) != 0
  guard request.workgroupCount > 0 || clearOnly else {
    throw fail("Metal draw request with zero workgroups must be marked clear-only")
  }
  guard request.workgroupCount == 0 || !clearOnly else {
    throw fail("Metal draw request cannot be both clear-only and non-empty")
  }
  if request.workgroupCount > 0 {
    guard request.frameParamsStride > 0 else {
      throw fail("Metal draw received a zero frame parameter stride")
    }
  }

  let resources =
    request.workgroupCount > 0
    ? try drawResources(context: context, request: request) : nil

  guard context.layer.pixelFormat == context.colorFormat else {
    throw fail("CAMetalLayer pixelFormat changed after Metal pipeline creation")
  }

  context.layer.drawableSize = CGSize(width: Int(request.width), height: Int(request.height))
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
    clearR: request.clearR,
    clearG: request.clearG,
    clearB: request.clearB,
    clearA: request.clearA
  )
  guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
    commandBuffer.endCommandBuffer()
    throw fail("renderCommandEncoderWithDescriptor returned nil")
  }

  if let resources {
    bindBuffer(frameSlot.arguments, resources.glyphPool, slot: bufferGlyphPool)
    bindBuffer(frameSlot.arguments, resources.glyphs, slot: bufferGlyphs)
    bindBuffer(frameSlot.arguments, resources.meshlets, slot: bufferMeshlets)
    #if HEAVY_SLUG_SHADER_STATS
      bindBuffer(frameSlot.arguments, resources.shaderStats, slot: bufferShaderStats)
    #endif

    encoder.setViewport(
      MTLViewport(
        originX: 0,
        originY: 0,
        width: Double(request.width),
        height: Double(request.height),
        znear: 0,
        zfar: 1
      ))
    encoder.setScissorRect(
      MTLScissorRect(x: 0, y: 0, width: Int(request.width), height: Int(request.height)))
    encoder.setCullMode(.none)
    encoder.setFrontFacing(.counterClockwise)
    encoder.setTriangleFillMode(.fill)
    encoder.setDepthClipMode(.clip)
    encoder.setDepthStencilState(nil)
    encoder.setRenderPipelineState(context.pipeline)

    var meshletBase: UInt32 = 0
    var chunkIndex: UInt32 = 0
    while meshletBase < request.workgroupCount {
      let chunkCount = min(request.workgroupCount - meshletBase, maxMeshThreadgroupsPerDraw)
      do {
        try bindFrameParams(
          table: frameSlot.arguments,
          frameParams: resources.frameParams,
          chunkIndex: chunkIndex,
          stride: request.frameParamsStride
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
public func hsMetalContextCreate(
  _ outContext: UnsafeMutablePointer<OpaquePointer?>?,
  _ device: UnsafeMutableRawPointer?,
  _ commandQueue: UnsafeMutableRawPointer?,
  _ layer: UnsafeMutableRawPointer?,
  _ libraryDataPtr: UnsafePointer<UInt8>?,
  _ librarySize: UInt,
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
      let library = try libraryData(libraryDataPtr, librarySize)
      let context = try MetalContext(
        devicePointer: device,
        commandQueuePointer: commandQueue,
        layerPointer: layer,
        library: library
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
public func hsMetalContextDestroy(_ contextHandle: OpaquePointer?) {
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
public func hsMetalContextWaitFrameSlot(
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
public func hsMetalContextReleaseFrameSlot(
  _ contextHandle: OpaquePointer?, _ slotIndex: UInt32
) {
  guard let context = try? borrowedContext(contextHandle), validSlotIndex(slotIndex) else {
    return
  }
  slot(context: context, index: slotIndex).releaseReservation()
}

@c(hs_metal_context_wait_submitted)
public func hsMetalContextWaitSubmitted(_ contextHandle: OpaquePointer?) {
  guard let context = try? borrowedContext(contextHandle) else {
    return
  }
  context.waitSubmitted()
}

@c(hs_metal_buffer_create)
public func hsMetalBufferCreate(
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
public func hsMetalBufferDestroy(_ bufferHandle: OpaquePointer?) {
  guard let bufferHandle else {
    return
  }
  _ = Unmanaged<MetalBuffer>.fromOpaque(UnsafeRawPointer(bufferHandle)).takeRetainedValue()
}

@c(hs_metal_buffer_contents)
public func hsMetalBufferContents(_ bufferHandle: OpaquePointer?) -> UnsafeMutableRawPointer? {
  guard let buffer = borrowedBuffer(bufferHandle) else {
    return nil
  }
  return buffer.buffer.contents()
}

@c(hs_metal_context_draw)
public func hsMetalContextDraw(
  _ contextHandle: OpaquePointer?,
  _ requestData: UnsafeRawPointer?,
  _ requestSize: UInt,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  autoreleasepool {
    let errorSink = ErrorSink(errorData, errorSize)
    do {
      let context = try borrowedContext(contextHandle)
      let request = try DrawRequest(data: requestData, size: requestSize)
      try draw(context: context, request: request)
      return statusOK
    } catch {
      errorSink.write(error)
      return statusError
    }
  }
}
