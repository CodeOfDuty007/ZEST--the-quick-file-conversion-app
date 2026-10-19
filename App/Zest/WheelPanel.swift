import AppKit
import SwiftUI
import ZestCore

/// The drop-target view. The OS drag is still live while the wheel is up, so the
/// pointer crossing this view produces `draggingEntered`/`draggingUpdated` here. It only
/// forwards offsets from the wheel centre; the controller decides what they mean.
@MainActor
final class WheelDropView: NSView {
  /// Returns the drag operation for the pointer's position (`.copy` only over a droppable leaf).
  var onPointer: ((_ dx: Double, _ dy: Double) -> NSDragOperation)?
  var onEntered: (() -> Void)?
  var onExited: (() -> Void)?
  /// Returns whether the drop was accepted.
  var onDrop: ((_ dx: Double, _ dy: Double, _ urls: [URL]) -> Bool)?
  /// The drag session finished over the wheel (drop or cancel), after any drop was handled.
  var onEnded: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func offset(_ sender: any NSDraggingInfo) -> (dx: Double, dy: Double) {
    let point = convert(sender.draggingLocation, from: nil)
    return (point.x - bounds.midX, point.y - bounds.midY)
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    onEntered?()
    let (dx, dy) = offset(sender)
    return onPointer?(dx, dy) ?? []
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let (dx, dy) = offset(sender)
    return onPointer?(dx, dy) ?? []
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) { onExited?() }

  override func draggingEnded(_ sender: any NSDraggingInfo) { onEnded?() }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let (dx, dy) = offset(sender)
    return onPointer?(dx, dy) == .copy
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let (dx, dy) = offset(sender)
    let urls =
      (sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    guard !urls.isEmpty else { return false }
    return onDrop?(dx, dy, urls) ?? false
  }
}

/// Borderless, non-activating panel. Non-activating matters: taking focus from Finder
/// can cancel the drag. It is built once at launch and only moved and shown after that.
@MainActor
final class WheelPanel: NSPanel {
  let dropView: WheelDropView
  private let model: WheelModel

  init(model: WheelModel) {
    self.model = model
    let side = WheelView.side
    let frame = NSRect(x: 0, y: 0, width: side, height: side)
    dropView = WheelDropView(frame: frame)
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)

    isFloatingPanel = true
    level = .popUpMenu
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    animationBehavior = .none

    let hosting = NSHostingView(rootView: WheelView(model: model))
    hosting.frame = frame
    hosting.autoresizingMask = [.width, .height]
    // AppKit delivers drags to the deepest view that registered types. If SwiftUI's
    // hosting view registered any, it would swallow the drop meant for `dropView`.
    let hostingTypes = hosting.registeredDraggedTypes
    if !hostingTypes.isEmpty {
      SpikeLog.shared.log(
        "NSHostingView had registered drag types, removed: \(hostingTypes.map(\.rawValue))")
      hosting.unregisterDraggedTypes()
    }
    dropView.addSubview(hosting)
    contentView = dropView
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Renders the SwiftUI tree once, invisibly, so the first real show does not pay for it.
  func prewarm() {
    setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    alphaValue = 0
    orderFrontRegardless()
    displayIfNeeded()
    orderOut(nil)
    alphaValue = 1
  }

  /// Centres the wheel on `point`, clamped into the visible frame of that screen.
  func present(at point: NSPoint) {
    let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    var origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
    if let visible = screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
      origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
    }
    setFrameOrigin(origin)
    model.isOpen = true
    orderFrontRegardless()
    displayIfNeeded()
  }

  func dismiss() {
    model.isOpen = false
    orderOut(nil)
  }
}
