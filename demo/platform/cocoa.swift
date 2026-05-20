// SwiftUI/AppKit demo host and Metal 4 object provider for the Zig demo.

import AppKit
import Foundation
import Metal
import Observation
import QuartzCore
import SwiftUI

private let statusOK: Int32 = 0
private let statusError: Int32 = 1
private let appName = "heavy-slug"
private let fallbackTitle = "heavy-slug Metal 4 demo"
private let preciseScrollScale = 0.1
private let hostProtocolVersion = protocolVersion(major: 2, minor: 0)

private func protocolVersion(major: UInt32, minor: UInt32) -> UInt32 {
  (major << 16) | minor
}

private func protocolVersionDescription(_ version: UInt32) -> String {
  "\(version >> 16).\(version & 0xffff)"
}

private enum DemoKey: Int {
  case escape = 0
  case space = 1
  case equal = 2
  case minus = 3
  case b = 4
  case r = 5
  case up = 6
  case down = 7
  case left = 8
  case right = 9
}

private enum MouseButton: Int {
  case left = 0
  case right = 1
}

private let keyCount = 10
private let mouseButtonCount = 2

private enum DemoColorScheme: UInt32, Equatable {
  case light = 0
  case dark = 1

  var appKitName: NSAppearance.Name {
    switch self {
    case .light:
      return .aqua
    case .dark:
      return .darkAqua
    }
  }

  var swiftUIValue: ColorScheme {
    switch self {
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

@MainActor
@Observable
private final class DemoAppearance {
  var scheme: DemoColorScheme = .light
}

private enum CreateRequestLayout {
  static let byteSize = 40
  static let protocolVersion = 0
  static let width = 4
  static let height = 8
  static let colorScheme = 12
  static let titleData = 16
  static let titleSize = 24
  static let reserved0 = 32
  static let reserved1 = 36
}

private enum SnapshotLayout {
  static let byteSize = 64
  static let protocolVersion = 0
  static let reserved0 = 4
  static let reserved1 = 8
  static let reserved2 = 12
  static let keys = 16
  static let mouseButtons = 26
  static let shouldClose = 28
  static let cursorX = 32
  static let cursorY = 40
  static let scrollDelta = 48
  static let framebufferWidth = 56
  static let framebufferHeight = 60
}

private enum MetalHostLayout {
  static let byteSize = 32
  static let protocolVersion = 0
  static let reserved0 = 4
  static let device = 8
  static let commandQueue = 16
  static let layer = 24
}

private struct HostFailure: Error, CustomStringConvertible {
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
    if let failure = error as? HostFailure {
      write(failure.message)
      return
    }

    let nsError = error as NSError
    if !nsError.localizedDescription.isEmpty {
      write(nsError.localizedDescription)
    } else {
      write(String(describing: error))
    }
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

private func fail(_ message: String) -> HostFailure {
  HostFailure(message: message)
}

private func checkedInt(_ value: UInt, _ label: String) throws -> Int {
  guard value <= UInt(Int.max) else {
    throw fail("\(label) exceeds Int.max")
  }
  return Int(value)
}

private func requireMainThread(_ operation: String) throws {
  guard Thread.isMainThread else {
    throw fail("\(operation) must be called on the main thread")
  }
}

private func requireLayoutSize(_ size: UInt, expected: Int, label: String) throws {
  guard size >= UInt(expected) else {
    throw fail("\(label) is smaller than the expected ABI size")
  }
}

private func requireProtocolVersion(_ actual: UInt32, label: String) throws {
  guard actual == hostProtocolVersion else {
    throw fail(
      "unsupported \(label) protocol version \(protocolVersionDescription(actual))"
    )
  }
}

private func loadABI<T>(_ data: UnsafeRawPointer, offset: Int, as type: T.Type = T.self) -> T {
  data.loadUnaligned(fromByteOffset: offset, as: type)
}

private func titleString(_ data: UnsafePointer<UInt8>?, _ size: UInt) throws -> String {
  if data == nil, size != 0 {
    throw fail("Cocoa window title pointer is null")
  }
  guard let data, size > 0 else {
    return fallbackTitle
  }

  let count = try checkedInt(size, "Cocoa window title size")
  let bytes = UnsafeBufferPointer(start: data, count: count)
  guard let title = String(bytes: bytes, encoding: .utf8) else {
    throw fail("Cocoa window title is not valid UTF-8")
  }
  return title
}

private func pixelDimension(_ value: CGFloat) -> UInt32 {
  guard value.isFinite, value > 0 else {
    return 0
  }
  let maxValue = CGFloat(UInt32.max)
  if value >= maxValue {
    return UInt32.max
  }
  return UInt32(value.rounded())
}

@MainActor
private func contentsScale(logicalBounds: CGRect, backingBounds: CGRect, window: NSWindow?)
  -> CGFloat
{
  let scaleX = logicalBounds.width > 0 ? backingBounds.width / logicalBounds.width : 0
  let scaleY = logicalBounds.height > 0 ? backingBounds.height / logicalBounds.height : 0
  let convertedScale = max(scaleX, scaleY)
  if convertedScale.isFinite, convertedScale > 0 {
    return convertedScale
  }

  if let window {
    let windowScale = window.backingScaleFactor
    if windowScale.isFinite, windowScale > 0 {
      return windowScale
    }
  }
  return 1
}

private struct CreateRequest {
  let width: UInt32
  let height: UInt32
  let colorScheme: DemoColorScheme
  let title: String

  init(data: UnsafeRawPointer?, size: UInt) throws {
    guard MemoryLayout<UInt>.size == 8, MemoryLayout<UnsafeRawPointer?>.size == 8 else {
      throw fail("Cocoa host ABI requires a 64-bit target")
    }
    guard let data else {
      throw fail("Cocoa window create received a null request")
    }
    try requireLayoutSize(
      size, expected: CreateRequestLayout.byteSize, label: "Cocoa create request")

    let version = loadABI(data, offset: CreateRequestLayout.protocolVersion, as: UInt32.self)
    try requireProtocolVersion(version, label: "Cocoa create request")

    let reserved0 = loadABI(data, offset: CreateRequestLayout.reserved0, as: UInt32.self)
    let reserved1 = loadABI(data, offset: CreateRequestLayout.reserved1, as: UInt32.self)
    guard reserved0 == 0, reserved1 == 0 else {
      throw fail("Cocoa create request reserved fields must be zero")
    }

    width = loadABI(data, offset: CreateRequestLayout.width, as: UInt32.self)
    height = loadABI(data, offset: CreateRequestLayout.height, as: UInt32.self)
    guard width > 0, height > 0 else {
      throw fail("Cocoa demo host requires a positive initial window size")
    }
    let schemeValue = loadABI(data, offset: CreateRequestLayout.colorScheme, as: UInt32.self)
    guard let colorScheme = DemoColorScheme(rawValue: schemeValue) else {
      throw fail("Cocoa create request color scheme is invalid")
    }
    self.colorScheme = colorScheme

    let titleData = loadABI(
      data, offset: CreateRequestLayout.titleData, as: UnsafePointer<UInt8>?.self)
    let titleSize = loadABI(data, offset: CreateRequestLayout.titleSize, as: UInt.self)
    title = try titleString(titleData, titleSize)
  }
}

private func zeroBytes(_ pointer: UnsafeMutableRawPointer, count: Int) {
  for offset in 0..<count {
    pointer.storeBytes(of: UInt8(0), toByteOffset: offset, as: UInt8.self)
  }
}

private func zeroBytes(_ pointer: UnsafeMutableRawPointer, capacity: UInt, limit: Int) {
  let writable = capacity > UInt(Int.max) ? limit : min(limit, Int(capacity))
  zeroBytes(pointer, count: writable)
}

private func writeBoolArray(_ values: [Bool], to pointer: UnsafeMutableRawPointer, offset: Int) {
  for index in 0..<values.count {
    pointer.storeBytes(
      of: values[index] ? UInt8(1) : UInt8(0),
      toByteOffset: offset + index,
      as: UInt8.self
    )
  }
}

private func writeEmptySnapshot(_ pointer: UnsafeMutableRawPointer?, size: UInt) {
  guard let pointer else {
    return
  }
  zeroBytes(pointer, capacity: size, limit: SnapshotLayout.byteSize)
  if size >= UInt(MemoryLayout<UInt32>.size) {
    pointer.storeBytes(
      of: hostProtocolVersion, toByteOffset: SnapshotLayout.protocolVersion, as: UInt32.self)
  }
}

@MainActor
private func writeSnapshot(
  _ host: DemoWindowHost?, to pointer: UnsafeMutableRawPointer?, size: UInt
)
  throws
{
  guard let pointer else {
    throw fail("Cocoa snapshot received a nil out parameter")
  }
  try requireLayoutSize(size, expected: SnapshotLayout.byteSize, label: "Cocoa snapshot")

  zeroBytes(pointer, count: SnapshotLayout.byteSize)
  pointer.storeBytes(
    of: hostProtocolVersion, toByteOffset: SnapshotLayout.protocolVersion, as: UInt32.self)
  guard let host else {
    return
  }

  writeBoolArray(host.keys, to: pointer, offset: SnapshotLayout.keys)
  writeBoolArray(host.mouseButtons, to: pointer, offset: SnapshotLayout.mouseButtons)
  pointer.storeBytes(
    of: host.shouldClose ? UInt8(1) : UInt8(0),
    toByteOffset: SnapshotLayout.shouldClose,
    as: UInt8.self
  )
  pointer.storeBytes(of: host.cursorX, toByteOffset: SnapshotLayout.cursorX, as: Double.self)
  pointer.storeBytes(of: host.cursorY, toByteOffset: SnapshotLayout.cursorY, as: Double.self)
  pointer.storeBytes(
    of: host.scrollDelta, toByteOffset: SnapshotLayout.scrollDelta, as: Double.self)
  pointer.storeBytes(
    of: host.framebufferWidth,
    toByteOffset: SnapshotLayout.framebufferWidth,
    as: UInt32.self
  )
  pointer.storeBytes(
    of: host.framebufferHeight,
    toByteOffset: SnapshotLayout.framebufferHeight,
    as: UInt32.self
  )
  host.scrollDelta = 0
}

private func writeEmptyMetalHost(_ pointer: UnsafeMutableRawPointer?, size: UInt) {
  guard let pointer else {
    return
  }
  zeroBytes(pointer, capacity: size, limit: MetalHostLayout.byteSize)
  if size >= UInt(MemoryLayout<UInt32>.size) {
    pointer.storeBytes(
      of: hostProtocolVersion, toByteOffset: MetalHostLayout.protocolVersion, as: UInt32.self)
  }
}

@MainActor
private func writeMetalHost(
  _ host: DemoWindowHost?, to pointer: UnsafeMutableRawPointer?, size: UInt
)
  throws
{
  guard let pointer else {
    throw fail("Cocoa Metal host received a nil out parameter")
  }
  try requireLayoutSize(size, expected: MetalHostLayout.byteSize, label: "Cocoa Metal host")

  writeEmptyMetalHost(pointer, size: size)
  guard let host else {
    throw fail("Cocoa Metal host received a null window handle")
  }

  pointer.storeBytes(
    of: hostProtocolVersion, toByteOffset: MetalHostLayout.protocolVersion, as: UInt32.self)
  let device = Unmanaged.passUnretained(host.device as AnyObject).toOpaque()
  let commandQueue = Unmanaged.passUnretained(host.commandQueue as AnyObject).toOpaque()
  let layer = Unmanaged.passUnretained(host.layer).toOpaque()
  pointer.storeBytes(
    of: device, toByteOffset: MetalHostLayout.device, as: UnsafeMutableRawPointer?.self)
  pointer.storeBytes(
    of: commandQueue,
    toByteOffset: MetalHostLayout.commandQueue,
    as: UnsafeMutableRawPointer?.self
  )
  pointer.storeBytes(
    of: layer, toByteOffset: MetalHostLayout.layer, as: UnsafeMutableRawPointer?.self)
}

@MainActor
private final class DemoWindowHost {
  var window: NSWindow?
  weak var view: HeavySlugDemoView?
  var delegate: HeavySlugDemoWindowDelegate?
  let device: MTLDevice
  let commandQueue: MTL4CommandQueue
  let layer: CAMetalLayer
  let appearance = DemoAppearance()
  let startTime = CACurrentMediaTime()

  var keys = Array(repeating: false, count: keyCount)
  var mouseButtons = Array(repeating: false, count: mouseButtonCount)
  var cursorX = 0.0
  var cursorY = 0.0
  var scrollDelta = 0.0
  var framebufferWidth: UInt32 = 0
  var framebufferHeight: UInt32 = 0
  var shouldClose = false

  init(device: MTLDevice, commandQueue: MTL4CommandQueue, layer: CAMetalLayer) {
    self.device = device
    self.commandQueue = commandQueue
    self.layer = layer
  }

  func resetInput() {
    keys = Array(repeating: false, count: keyCount)
    mouseButtons = Array(repeating: false, count: mouseButtonCount)
    scrollDelta = 0
  }

  func attach(view: HeavySlugDemoView) {
    self.view = view
    view.host = self
    view.wantsLayer = true
    view.layer = layer
    view.layerContentsRedrawPolicy = .never
    applyAppearance()
    updateDrawableSize()
  }

  func detach(view: HeavySlugDemoView) {
    if self.view === view {
      self.view = nil
    }
    view.host = nil
  }

  func updateDrawableSize() {
    guard let view else {
      framebufferWidth = 0
      framebufferHeight = 0
      return
    }

    let bounds = view.bounds
    layer.frame = bounds
    guard bounds.width > 0, bounds.height > 0 else {
      framebufferWidth = 0
      framebufferHeight = 0
      return
    }

    let backingBounds = view.convertToBacking(bounds)
    let width = pixelDimension(backingBounds.width)
    let height = pixelDimension(backingBounds.height)
    guard width > 0, height > 0 else {
      framebufferWidth = 0
      framebufferHeight = 0
      return
    }

    layer.contentsScale = contentsScale(
      logicalBounds: bounds, backingBounds: backingBounds, window: window)
    layer.drawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    framebufferWidth = width
    framebufferHeight = height
  }

  func updateCursor(in view: NSView, point: CGPoint) {
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0, framebufferWidth > 0, framebufferHeight > 0 else {
      cursorX = 0
      cursorY = 0
      return
    }

    cursorX = point.x * (Double(framebufferWidth) / bounds.width)
    cursorY = point.y * (Double(framebufferHeight) / bounds.height)
  }

  func setKey(_ key: DemoKey, pressed: Bool) {
    keys[key.rawValue] = pressed
  }

  func setMouseButton(_ button: MouseButton, pressed: Bool) {
    mouseButtons[button.rawValue] = pressed
  }

  func setColorScheme(_ scheme: DemoColorScheme) {
    if appearance.scheme != scheme {
      appearance.scheme = scheme
    }
    applyAppearance()
  }

  func applyAppearance() {
    guard let appKitAppearance = NSAppearance(named: appearance.scheme.appKitName) else {
      return
    }

    NSApplication.shared.appearance = appKitAppearance
    window?.appearance = appKitAppearance
    window?.contentView?.appearance = appKitAppearance
    view?.appearance = appKitAppearance
  }
}

@MainActor
private final class HeavySlugDemoAppDelegate: NSObject, NSApplicationDelegate {
  weak var activeHost: DemoWindowHost?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let activeHost else {
      return .terminateNow
    }
    activeHost.shouldClose = true
    activeHost.resetInput()
    return .terminateCancel
  }

  func applicationDidResignActive(_ notification: Notification) {
    activeHost?.resetInput()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    guard let activeHost, !activeHost.shouldClose else {
      return false
    }
    activeHost.window?.deminiaturize(nil)
    activeHost.window?.makeKeyAndOrderFront(nil)
    sender.activate()
    return true
  }
}

private final class HeavySlugDemoView: NSView {
  weak var host: DemoWindowHost?
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  func detachHost() {
    removeCurrentTrackingArea()
    host?.detach(view: self)
    host = nil
    layer = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
    updateTrackingAreas()
    host?.updateDrawableSize()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    host?.updateDrawableSize()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    host?.updateDrawableSize()
  }

  override func setBoundsSize(_ newSize: NSSize) {
    super.setBoundsSize(newSize)
    host?.updateDrawableSize()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    removeCurrentTrackingArea()

    let options: NSTrackingArea.Options = [
      .mouseMoved,
      .cursorUpdate,
      .activeInKeyWindow,
      .inVisibleRect,
      .enabledDuringMouseDrag,
    ]
    let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    self.trackingArea = trackingArea
    addTrackingArea(trackingArea)
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func keyDown(with event: NSEvent) {
    guard let host, !event.modifierFlags.contains(.command), let key = keyForEvent(event) else {
      super.keyDown(with: event)
      return
    }
    host.setKey(key, pressed: true)
  }

  override func keyUp(with event: NSEvent) {
    guard let host, let key = keyForEvent(event) else {
      super.keyUp(with: event)
      return
    }
    host.setKey(key, pressed: false)
  }

  override func mouseDown(with event: NSEvent) {
    recordCursor(event)
    host?.setMouseButton(.left, pressed: true)
  }

  override func mouseUp(with event: NSEvent) {
    recordCursor(event)
    host?.setMouseButton(.left, pressed: false)
  }

  override func rightMouseDown(with event: NSEvent) {
    recordCursor(event)
    host?.setMouseButton(.right, pressed: true)
  }

  override func rightMouseUp(with event: NSEvent) {
    recordCursor(event)
    host?.setMouseButton(.right, pressed: false)
  }

  override func mouseMoved(with event: NSEvent) {
    recordCursor(event)
  }

  override func mouseDragged(with event: NSEvent) {
    recordCursor(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    recordCursor(event)
  }

  override func scrollWheel(with event: NSEvent) {
    recordCursor(event)
    let delta =
      event.hasPreciseScrollingDeltas
      ? event.scrollingDeltaY * preciseScrollScale
      : event.scrollingDeltaY
    host?.scrollDelta += delta
  }

  private func removeCurrentTrackingArea() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
      self.trackingArea = nil
    }
  }

  private func recordCursor(_ event: NSEvent) {
    guard let host else {
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    host.updateCursor(in: self, point: point)
  }
}

@MainActor
private final class HeavySlugDemoWindowDelegate: NSObject, NSWindowDelegate {
  weak var host: DemoWindowHost?

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let host else {
      return false
    }
    host.shouldClose = true
    host.resetInput()
    return false
  }

  func windowDidResize(_ notification: Notification) {
    host?.updateDrawableSize()
  }

  func windowDidChangeBackingProperties(_ notification: Notification) {
    host?.updateDrawableSize()
  }

  func windowDidChangeScreen(_ notification: Notification) {
    host?.updateDrawableSize()
  }

  func windowDidResignKey(_ notification: Notification) {
    host?.resetInput()
  }

  func windowDidMiniaturize(_ notification: Notification) {
    host?.resetInput()
  }
}

private struct HeavySlugMetalSurface: NSViewRepresentable {
  let host: DemoWindowHost
  let colorScheme: ColorScheme

  func makeNSView(context: Context) -> HeavySlugDemoView {
    let view = HeavySlugDemoView(frame: .zero)
    host.attach(view: view)
    return view
  }

  func updateNSView(_ nsView: HeavySlugDemoView, context: Context) {
    _ = colorScheme
    if nsView.layer !== host.layer {
      nsView.layer = host.layer
    }
    host.attach(view: nsView)
  }

  static func dismantleNSView(_ nsView: HeavySlugDemoView, coordinator: ()) {
    nsView.detachHost()
  }
}

private struct HeavySlugDemoRootView: View {
  let appearance: DemoAppearance
  let host: DemoWindowHost

  var body: some View {
    let scheme = appearance.scheme.swiftUIValue
    HeavySlugMetalSurface(host: host, colorScheme: scheme)
      .preferredColorScheme(scheme)
  }
}

@MainActor
private final class AppState {
  static let shared = AppState()
  var delegate: HeavySlugDemoAppDelegate?
  var finishedLaunching = false
  var installedMenu = false
}

private func keyForCharacter(_ character: UInt16) -> DemoKey? {
  switch character {
  case 0x1b:
    return .escape
  case 0x20:
    return .space
  case 0x3d, 0x2b:
    return .equal
  case 0x2d, 0x5f:
    return .minus
  case 0x62, 0x42:
    return .b
  case 0x72, 0x52:
    return .r
  case UInt16(NSUpArrowFunctionKey):
    return .up
  case UInt16(NSDownArrowFunctionKey):
    return .down
  case UInt16(NSLeftArrowFunctionKey):
    return .left
  case UInt16(NSRightArrowFunctionKey):
    return .right
  default:
    return nil
  }
}

private func keyForEvent(_ event: NSEvent) -> DemoKey? {
  guard let characters = event.charactersIgnoringModifiers,
    let character = characters.utf16.first
  else {
    return nil
  }
  return keyForCharacter(character)
}

@MainActor
private func installMainMenu(_ app: NSApplication) {
  let state = AppState.shared
  guard !state.installedMenu else {
    return
  }

  let mainMenu = NSMenu(title: "")
  let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  let appMenu = NSMenu(title: appName)

  let aboutItem = NSMenuItem(
    title: "About heavy-slug",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    keyEquivalent: ""
  )
  aboutItem.target = app
  appMenu.addItem(aboutItem)
  appMenu.addItem(.separator())

  let quitItem = NSMenuItem(
    title: "Quit heavy-slug",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
  )
  quitItem.target = app
  quitItem.keyEquivalentModifierMask = .command
  appMenu.addItem(quitItem)

  appMenuItem.submenu = appMenu
  mainMenu.addItem(appMenuItem)

  let fileMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  let fileMenu = NSMenu(title: "File")
  let closeItem = NSMenuItem(
    title: "Close Window",
    action: #selector(NSWindow.performClose(_:)),
    keyEquivalent: "w"
  )
  closeItem.keyEquivalentModifierMask = .command
  fileMenu.addItem(closeItem)
  fileMenuItem.submenu = fileMenu
  mainMenu.addItem(fileMenuItem)

  app.mainMenu = mainMenu
  state.installedMenu = true
}

@MainActor
private func ensureApplication() {
  let app = NSApplication.shared
  let state = AppState.shared
  if state.delegate == nil {
    let delegate = HeavySlugDemoAppDelegate()
    state.delegate = delegate
    app.delegate = delegate
  }

  app.setActivationPolicy(.regular)
  installMainMenu(app)
  if !state.finishedLaunching {
    app.finishLaunching()
    state.finishedLaunching = true
  }
}

@MainActor
private func makeDevice() throws -> MTLDevice {
  guard let device = MTLCreateSystemDefaultDevice() else {
    throw fail("MTLCreateSystemDefaultDevice returned nil")
  }
  guard device.supportsFamily(.metal4) else {
    throw fail("heavy-slug Metal demo requires a Metal 4 family GPU")
  }
  return device
}

@MainActor
private func makeCommandQueue(device: MTLDevice) throws -> MTL4CommandQueue {
  let descriptor = MTL4CommandQueueDescriptor()
  descriptor.label = "heavy-slug demo command queue"
  return try device.makeMTL4CommandQueue(descriptor: descriptor)
}

@MainActor
private func makeMetalLayer(device: MTLDevice) -> CAMetalLayer {
  let layer = CAMetalLayer()
  layer.device = device
  layer.pixelFormat = .bgra8Unorm
  layer.framebufferOnly = true
  layer.displaySyncEnabled = true
  layer.presentsWithTransaction = false
  layer.allowsNextDrawableTimeout = true
  layer.isOpaque = true
  _ = layer.residencySet
  return layer
}

@MainActor
private func makeWindow(_ request: CreateRequest) throws -> DemoWindowHost {
  try requireMainThread("Cocoa window create")
  ensureApplication()

  let device = try makeDevice()
  let commandQueue = try makeCommandQueue(device: device)
  let layer = makeMetalLayer(device: device)
  let host = DemoWindowHost(device: device, commandQueue: commandQueue, layer: layer)
  host.setColorScheme(request.colorScheme)

  let rect = NSRect(x: 0, y: 0, width: Int(request.width), height: Int(request.height))
  let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
  let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
  window.title = request.title
  window.isReleasedWhenClosed = false
  window.tabbingMode = .disallowed
  window.contentMinSize = NSSize(width: 320, height: 200)

  let delegate = HeavySlugDemoWindowDelegate()
  delegate.host = host
  host.window = window
  host.delegate = delegate

  let rootView = HeavySlugDemoRootView(appearance: host.appearance, host: host)
  let hostingView = NSHostingView(rootView: rootView)
  hostingView.frame = rect
  hostingView.autoresizingMask = [.width, .height]
  window.contentView = hostingView
  window.delegate = delegate
  AppState.shared.delegate?.activeHost = host
  host.applyAppearance()

  window.center()
  window.makeKeyAndOrderFront(nil)
  NSApplication.shared.activate()
  host.updateDrawableSize()
  return host
}

private func retainedHandle<T: AnyObject>(_ object: T) -> OpaquePointer {
  OpaquePointer(Unmanaged.passRetained(object).toOpaque())
}

@MainActor
private func borrowedHost(_ handle: OpaquePointer?) -> DemoWindowHost? {
  guard let handle else {
    return nil
  }
  return Unmanaged<DemoWindowHost>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

@c(hs_demo_cocoa_window_create)
public func hsDemoCocoaWindowCreate(
  _ outWindow: UnsafeMutablePointer<OpaquePointer?>?,
  _ requestData: UnsafeRawPointer?,
  _ requestSize: UInt,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  let errorSink = ErrorSink(errorData, errorSize)
  guard Thread.isMainThread else {
    errorSink.write("Cocoa window create must be called on the main thread")
    return statusError
  }
  nonisolated(unsafe) let unsafeOutWindow = outWindow
  nonisolated(unsafe) let unsafeRequestData = requestData
  nonisolated(unsafe) let unsafeErrorSink = errorSink

  return MainActor.assumeIsolated {
    autoreleasepool {
      guard let outWindow = unsafeOutWindow else {
        unsafeErrorSink.write("Cocoa window create received a nil out parameter")
        return statusError
      }
      outWindow.pointee = nil

      do {
        let request = try CreateRequest(data: unsafeRequestData, size: requestSize)
        let host = try makeWindow(request)
        outWindow.pointee = retainedHandle(host)
        return statusOK
      } catch {
        unsafeErrorSink.write(error)
        return statusError
      }
    }
  }
}

@c(hs_demo_cocoa_window_destroy)
public func hsDemoCocoaWindowDestroy(_ hostHandle: OpaquePointer?) {
  guard Thread.isMainThread, let hostHandle else {
    return
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle

  MainActor.assumeIsolated {
    autoreleasepool {
      let host = Unmanaged<DemoWindowHost>.fromOpaque(UnsafeRawPointer(unsafeHostHandle))
        .takeRetainedValue()
      if AppState.shared.delegate?.activeHost === host {
        AppState.shared.delegate?.activeHost = nil
      }
      host.resetInput()
      host.view?.detachHost()
      host.delegate?.host = nil
      host.window?.delegate = nil
      host.window?.contentView = nil
      host.window?.close()
      host.window = nil
      host.delegate = nil
    }
  }
}

@c(hs_demo_cocoa_window_poll_events)
public func hsDemoCocoaWindowPollEvents(_ hostHandle: OpaquePointer?) {
  guard Thread.isMainThread else {
    return
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle

  MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle) else {
      return
    }

    autoreleasepool {
      let app = NSApplication.shared
      while let event = app.nextEvent(
        matching: .any,
        until: .distantPast,
        inMode: .default,
        dequeue: true
      ) {
        app.sendEvent(event)
      }
      app.updateWindows()
      host.updateDrawableSize()
    }
  }
}

@c(hs_demo_cocoa_window_set_color_scheme)
public func hsDemoCocoaWindowSetColorScheme(_ hostHandle: OpaquePointer?, _ schemeValue: UInt32) {
  guard Thread.isMainThread else {
    return
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle

  MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle),
      let scheme = DemoColorScheme(rawValue: schemeValue)
    else {
      return
    }
    host.setColorScheme(scheme)
  }
}

@c(hs_demo_cocoa_window_snapshot)
public func hsDemoCocoaWindowSnapshot(
  _ hostHandle: OpaquePointer?,
  _ snapshotData: UnsafeMutableRawPointer?,
  _ snapshotSize: UInt
) -> Int32 {
  guard Thread.isMainThread else {
    writeEmptySnapshot(snapshotData, size: snapshotSize)
    return statusError
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle
  nonisolated(unsafe) let unsafeSnapshotData = snapshotData

  return MainActor.assumeIsolated {
    do {
      try writeSnapshot(
        borrowedHost(unsafeHostHandle),
        to: unsafeSnapshotData,
        size: snapshotSize
      )
      return statusOK
    } catch {
      writeEmptySnapshot(unsafeSnapshotData, size: snapshotSize)
      return statusError
    }
  }
}

@c(hs_demo_cocoa_window_time)
public func hsDemoCocoaWindowTime(_ hostHandle: OpaquePointer?) -> Double {
  guard Thread.isMainThread else {
    return 0
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle

  return MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle) else {
      return 0
    }
    return CACurrentMediaTime() - host.startTime
  }
}

@c(hs_demo_cocoa_window_metal_host)
public func hsDemoCocoaWindowMetalHost(
  _ hostHandle: OpaquePointer?,
  _ hostData: UnsafeMutableRawPointer?,
  _ hostSize: UInt
) -> Int32 {
  writeEmptyMetalHost(hostData, size: hostSize)
  guard Thread.isMainThread else {
    return statusError
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle
  nonisolated(unsafe) let unsafeHostData = hostData

  return MainActor.assumeIsolated {
    do {
      try writeMetalHost(borrowedHost(unsafeHostHandle), to: unsafeHostData, size: hostSize)
      return statusOK
    } catch {
      writeEmptyMetalHost(unsafeHostData, size: hostSize)
      return statusError
    }
  }
}
