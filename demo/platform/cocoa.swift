// SwiftUI/AppKit demo host and Metal 4 object provider for the Zig demo.

import AppKit
import Combine
import Foundation
import Metal
import QuartzCore
import SwiftUI

private let statusOK: Int32 = 0
private let statusError: Int32 = 1
private let fallbackTitle = "heavy-slug Metal 4 demo"
private let appName = "heavy-slug"
private let preciseScrollScale = 0.1

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

private enum DemoColorScheme {
  case light
  case dark

  init(darkModeEnabled: Bool) {
    self = darkModeEnabled ? .dark : .light
  }

  var appearanceName: NSAppearance.Name {
    switch self {
    case .light:
      return .aqua
    case .dark:
      return .darkAqua
    }
  }

  var swiftUIColorScheme: ColorScheme {
    switch self {
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

private let keyCount = 10
private let mouseButtonCount = 2

@MainActor
private final class DemoAppearance: ObservableObject {
  @Published var scheme: DemoColorScheme = .light
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

private func requireMainThread() throws {
  guard Thread.isMainThread else {
    throw fail("Cocoa demo host must be used on the main thread")
  }
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

@MainActor
private final class DemoWindowHost {
  var window: NSWindow?
  weak var view: HeavySlugDemoView?
  var delegate: HeavySlugDemoWindowDelegate?
  let device: MTLDevice
  let commandQueue: MTL4CommandQueue
  let layer: CAMetalLayer
  var keys = Array(repeating: false, count: keyCount)
  var mouseButtons = Array(repeating: false, count: mouseButtonCount)
  var cursorX = 0.0
  var cursorY = 0.0
  var scrollDelta = 0.0
  var framebufferWidth: UInt32 = 0
  var framebufferHeight: UInt32 = 0
  var shouldClose = false
  let appearance = DemoAppearance()
  let startTime = CACurrentMediaTime()

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

  func updateDrawableSize() {
    guard let window, let view else {
      return
    }

    let logicalBounds = view.bounds
    layer.frame = logicalBounds
    guard logicalBounds.width > 0, logicalBounds.height > 0 else {
      layer.drawableSize = .zero
      framebufferWidth = 0
      framebufferHeight = 0
      return
    }

    let backingBounds = view.convertToBacking(logicalBounds)
    let width = pixelDimension(backingBounds.width)
    let height = pixelDimension(backingBounds.height)
    layer.contentsScale = contentsScale(
      logicalBounds: logicalBounds,
      backingBounds: backingBounds,
      window: window
    )
    layer.drawableSize = CGSize(width: Int(width), height: Int(height))
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

  func setDarkMode(_ enabled: Bool) {
    let nextScheme = DemoColorScheme(darkModeEnabled: enabled)
    if appearance.scheme != nextScheme {
      appearance.scheme = nextScheme
    }
    applyAppearance()
  }

  func applyAppearance() {
    guard let appKitAppearance = NSAppearance(named: appearance.scheme.appearanceName) else {
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
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    true
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
    if let tracking {
      removeTrackingArea(tracking)
      self.tracking = nil
    }

    let options: NSTrackingArea.Options = [
      .mouseMoved,
      .cursorUpdate,
      .activeInKeyWindow,
      .inVisibleRect,
      .enabledDuringMouseDrag,
    ]
    let tracking = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    self.tracking = tracking
    addTrackingArea(tracking)
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  private func recordCursor(_ event: NSEvent) {
    guard let host else {
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    host.updateCursor(in: self, point: point)
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

  func makeNSView(context: Context) -> HeavySlugDemoView {
    let view = HeavySlugDemoView(frame: .zero)
    view.host = host
    view.wantsLayer = true
    view.layer = host.layer
    view.layerContentsRedrawPolicy = .never
    host.view = view
    host.applyAppearance()
    return view
  }

  func updateNSView(_ nsView: HeavySlugDemoView, context: Context) {
    nsView.host = host
    if nsView.layer !== host.layer {
      nsView.layer = host.layer
    }
    host.view = nsView
    host.applyAppearance()
    host.updateDrawableSize()
  }
}

private struct HeavySlugDemoRootView: View {
  @ObservedObject var appearance: DemoAppearance
  let host: DemoWindowHost

  var body: some View {
    HeavySlugMetalSurface(host: host)
      .preferredColorScheme(appearance.scheme.swiftUIColorScheme)
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
private func installMainMenu(_ app: NSApplication) throws {
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
private func ensureApplication() throws {
  let app = NSApplication.shared
  let state = AppState.shared
  if state.delegate == nil {
    let delegate = HeavySlugDemoAppDelegate()
    state.delegate = delegate
    app.delegate = delegate
  }

  app.setActivationPolicy(.regular)
  try installMainMenu(app)
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
private func makeMetalLayer(device: MTLDevice) throws -> CAMetalLayer {
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
private func makeWindow(width: UInt32, height: UInt32, title: String) throws -> DemoWindowHost {
  try requireMainThread()
  guard width > 0, height > 0 else {
    throw fail("Cocoa demo host requires a positive initial window size")
  }

  try ensureApplication()
  let device = try makeDevice()
  let commandQueue = try makeCommandQueue(device: device)
  let layer = try makeMetalLayer(device: device)
  let host = DemoWindowHost(device: device, commandQueue: commandQueue, layer: layer)

  let rect = NSRect(x: 0, y: 0, width: Int(width), height: Int(height))
  let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
  let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
  window.title = title
  window.isReleasedWhenClosed = false
  window.tabbingMode = .disallowed

  let delegate = HeavySlugDemoWindowDelegate()
  delegate.host = host
  host.window = window
  host.delegate = delegate

  let hostingView = NSHostingView(
    rootView: HeavySlugDemoRootView(appearance: host.appearance, host: host))
  hostingView.frame = rect
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

private func writeBoolArray(_ values: [Bool], to pointer: UnsafeMutablePointer<UInt8>?, count: UInt)
{
  guard let pointer else {
    return
  }

  let writable = count > UInt(Int.max) ? values.count : min(values.count, Int(count))
  for index in 0..<writable {
    pointer.advanced(by: index).pointee = values[index] ? 1 : 0
  }
}

private func writeRepeatedByte(
  _ value: UInt8,
  to pointer: UnsafeMutablePointer<UInt8>?,
  capacity: UInt,
  maxCount: Int
) {
  guard let pointer else {
    return
  }

  let capacityCount = capacity > UInt(Int.max) ? Int.max : Int(capacity)
  let writable = min(capacityCount, maxCount)
  for index in 0..<writable {
    pointer.advanced(by: index).pointee = value
  }
}

private func writeEmptySnapshot(
  keys: UnsafeMutablePointer<UInt8>?,
  keyCapacity: UInt,
  mouseButtons: UnsafeMutablePointer<UInt8>?,
  mouseButtonCapacity: UInt,
  cursorX: UnsafeMutablePointer<Double>?,
  cursorY: UnsafeMutablePointer<Double>?,
  scrollDelta: UnsafeMutablePointer<Double>?,
  framebufferWidth: UnsafeMutablePointer<UInt32>?,
  framebufferHeight: UnsafeMutablePointer<UInt32>?,
  shouldClose: UnsafeMutablePointer<UInt8>?
) {
  writeRepeatedByte(0, to: keys, capacity: keyCapacity, maxCount: keyCount)
  writeRepeatedByte(0, to: mouseButtons, capacity: mouseButtonCapacity, maxCount: mouseButtonCount)
  cursorX?.pointee = 0
  cursorY?.pointee = 0
  scrollDelta?.pointee = 0
  framebufferWidth?.pointee = 0
  framebufferHeight?.pointee = 0
  shouldClose?.pointee = 0
}

@c(hs_demo_cocoa_window_create)
public func hsDemoCocoaWindowCreate(
  _ outWindow: UnsafeMutablePointer<OpaquePointer?>?,
  _ width: UInt32,
  _ height: UInt32,
  _ titleData: UnsafePointer<UInt8>?,
  _ titleSize: UInt,
  _ errorData: UnsafeMutablePointer<UInt8>?,
  _ errorSize: UInt
) -> Int32 {
  let errorSink = ErrorSink(errorData, errorSize)
  guard Thread.isMainThread else {
    errorSink.write("Cocoa window create must be called on the main thread")
    return statusError
  }
  nonisolated(unsafe) let unsafeOutWindow = outWindow
  nonisolated(unsafe) let unsafeTitleData = titleData
  nonisolated(unsafe) let unsafeErrorSink = errorSink

  return MainActor.assumeIsolated {
    autoreleasepool {
      guard let outWindow = unsafeOutWindow else {
        unsafeErrorSink.write("Cocoa window create received a nil out parameter")
        return statusError
      }
      outWindow.pointee = nil

      do {
        let title = try titleString(unsafeTitleData, titleSize)
        let host = try makeWindow(width: width, height: height, title: title)
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
      host.view?.host = nil
      host.delegate?.host = nil
      host.window?.orderOut(nil)
      host.window?.delegate = nil
      host.window?.contentView = nil
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

@c(hs_demo_cocoa_window_set_dark_mode)
public func hsDemoCocoaWindowSetDarkMode(_ hostHandle: OpaquePointer?, _ enabled: UInt8) {
  guard Thread.isMainThread else {
    return
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle

  MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle) else {
      return
    }
    host.setDarkMode(enabled != 0)
  }
}

@c(hs_demo_cocoa_window_snapshot)
public func hsDemoCocoaWindowSnapshot(
  _ hostHandle: OpaquePointer?,
  _ keys: UnsafeMutablePointer<UInt8>?,
  _ keyCapacity: UInt,
  _ mouseButtons: UnsafeMutablePointer<UInt8>?,
  _ mouseButtonCapacity: UInt,
  _ cursorX: UnsafeMutablePointer<Double>?,
  _ cursorY: UnsafeMutablePointer<Double>?,
  _ scrollDelta: UnsafeMutablePointer<Double>?,
  _ framebufferWidth: UnsafeMutablePointer<UInt32>?,
  _ framebufferHeight: UnsafeMutablePointer<UInt32>?,
  _ shouldClose: UnsafeMutablePointer<UInt8>?
) {
  guard Thread.isMainThread else {
    writeEmptySnapshot(
      keys: keys,
      keyCapacity: keyCapacity,
      mouseButtons: mouseButtons,
      mouseButtonCapacity: mouseButtonCapacity,
      cursorX: cursorX,
      cursorY: cursorY,
      scrollDelta: scrollDelta,
      framebufferWidth: framebufferWidth,
      framebufferHeight: framebufferHeight,
      shouldClose: shouldClose
    )
    return
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle
  nonisolated(unsafe) let unsafeKeys = keys
  nonisolated(unsafe) let unsafeMouseButtons = mouseButtons
  nonisolated(unsafe) let unsafeCursorX = cursorX
  nonisolated(unsafe) let unsafeCursorY = cursorY
  nonisolated(unsafe) let unsafeScrollDelta = scrollDelta
  nonisolated(unsafe) let unsafeFramebufferWidth = framebufferWidth
  nonisolated(unsafe) let unsafeFramebufferHeight = framebufferHeight
  nonisolated(unsafe) let unsafeShouldClose = shouldClose

  MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle) else {
      writeEmptySnapshot(
        keys: unsafeKeys,
        keyCapacity: keyCapacity,
        mouseButtons: unsafeMouseButtons,
        mouseButtonCapacity: mouseButtonCapacity,
        cursorX: unsafeCursorX,
        cursorY: unsafeCursorY,
        scrollDelta: unsafeScrollDelta,
        framebufferWidth: unsafeFramebufferWidth,
        framebufferHeight: unsafeFramebufferHeight,
        shouldClose: unsafeShouldClose
      )
      return
    }

    writeBoolArray(host.keys, to: unsafeKeys, count: keyCapacity)
    writeBoolArray(host.mouseButtons, to: unsafeMouseButtons, count: mouseButtonCapacity)
    unsafeCursorX?.pointee = host.cursorX
    unsafeCursorY?.pointee = host.cursorY
    unsafeScrollDelta?.pointee = host.scrollDelta
    unsafeFramebufferWidth?.pointee = host.framebufferWidth
    unsafeFramebufferHeight?.pointee = host.framebufferHeight
    unsafeShouldClose?.pointee = host.shouldClose ? 1 : 0
    host.scrollDelta = 0
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
  _ outDevice: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  _ outCommandQueue: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
  _ outLayer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
  outDevice?.pointee = nil
  outCommandQueue?.pointee = nil
  outLayer?.pointee = nil

  guard Thread.isMainThread else {
    return statusError
  }
  nonisolated(unsafe) let unsafeHostHandle = hostHandle
  nonisolated(unsafe) let unsafeOutDevice = outDevice
  nonisolated(unsafe) let unsafeOutCommandQueue = outCommandQueue
  nonisolated(unsafe) let unsafeOutLayer = outLayer

  return MainActor.assumeIsolated {
    guard let host = borrowedHost(unsafeHostHandle) else {
      unsafeOutDevice?.pointee = nil
      unsafeOutCommandQueue?.pointee = nil
      unsafeOutLayer?.pointee = nil
      return statusError
    }

    unsafeOutDevice?.pointee = Unmanaged.passUnretained(host.device as AnyObject).toOpaque()
    unsafeOutCommandQueue?.pointee = Unmanaged.passUnretained(host.commandQueue as AnyObject)
      .toOpaque()
    unsafeOutLayer?.pointee = Unmanaged.passUnretained(host.layer).toOpaque()
    return statusOK
  }
}
