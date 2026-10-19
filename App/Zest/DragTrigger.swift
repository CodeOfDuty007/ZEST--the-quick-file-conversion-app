import AppKit
import CoreGraphics

/// All OS-specific drag detection lives here (module rule from the plan).
///
/// Mouse monitors only arm the detector; nothing runs between drags. A real file drag
/// is recognised when the drag pasteboard's changeCount advances past its mouse-down
/// value and it carries file URLs.
@MainActor
final class DragTrigger {
  enum ModifierSource: String, CaseIterable, Identifiable {
    case nsEvent = "NSEvent monitor"
    case eventTap = "CGEventTap"
    var id: String { rawValue }
  }

  /// URLs on the drag pasteboard plus its raw type list, for diagnostics.
  var onDragBegan: (([URL], [String]) -> Void)?
  var onDragEnded: (() -> Void)?
  /// Called when the trigger modifier goes down mid-drag. The value is the uptime at
  /// handler entry, the zero point for latency measurements.
  var onModifierDown: ((TimeInterval) -> Void)?
  var onNote: ((String) -> Void)?

  private(set) var modifierEventCount = 0
  private(set) var isDragActive = false

  /// When false, the latency-critical activity is skipped so App Nap can be compared.
  var holdsLatencyActivity = true

  private var mouseMonitor: Any?
  private var flagsMonitor: Any?
  private var eventTap: ModifierEventTap?

  private var armed = false
  private var baselineChangeCount = 0
  private var activity: NSObjectProtocol?
  private var shiftWasDown = false
  private var shiftDownAt: TimeInterval = 0

  /// The modifier that opens the wheel. Shift for now; remappable in Phase 2 (F-25).
  private let trigger: NSEvent.ModifierFlags = .shift
  private let tapWindow: TimeInterval = 0.350

  func start(source: ModifierSource) {
    stop()
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      let type = event.type
      MainActor.assumeIsolated { self?.handleMouse(type) }
    }

    switch source {
    case .nsEvent:
      flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        let flags = event.modifierFlags
        let delivery = ProcessInfo.processInfo.systemUptime - event.timestamp
        MainActor.assumeIsolated { self?.handleFlags(flags, deliveryDelay: delivery) }
      }
    case .eventTap:
      let tap = ModifierEventTap { [weak self] flags in
        MainActor.assumeIsolated { self?.handleFlags(flags, deliveryDelay: nil) }
      }
      if tap.install() {
        eventTap = tap
        onNote?("CGEventTap installed")
      } else {
        onNote?("CGEventTap could not be created (Input Monitoring not granted?)")
      }
    }
    onNote?("Trigger started using \(source.rawValue)")
  }

  func stop() {
    if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    mouseMonitor = nil
    flagsMonitor = nil
    eventTap?.remove()
    eventTap = nil
    endDrag()
    armed = false
  }

  // MARK: Mouse

  private func handleMouse(_ type: NSEvent.EventType) {
    switch type {
    case .leftMouseDown:
      // A drop elsewhere can swallow the mouse-up. Never let that lock out the next drag.
      if isDragActive {
        endDrag()
        onDragEnded?()
      }
      armed = true
      baselineChangeCount = NSPasteboard(name: .drag).changeCount
    case .leftMouseDragged:
      guard armed, !isDragActive else { return }
      let pasteboard = NSPasteboard(name: .drag)
      guard pasteboard.changeCount != baselineChangeCount else { return }
      // The session has started; decide once, then stop checking until the next mouse-down.
      armed = false
      let types = pasteboard.types?.map(\.rawValue) ?? []
      let urls =
        (pasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
      guard !urls.isEmpty else {
        let promised = pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self])
        onNote?(
          "Drag without file URLs (promise=\(promised)) types=\(types.prefix(6).joined(separator: ","))"
        )
        return
      }
      beginDrag()
      onDragBegan?(urls, types)
    case .leftMouseUp:
      armed = false
      if isDragActive {
        endDrag()
        onDragEnded?()
      }
    default:
      break
    }
  }

  private func beginDrag() {
    isDragActive = true
    // Opt out of App Nap and timer coalescing while a drag is live (fixes lag after idle).
    if holdsLatencyActivity {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "File drag in progress")
    }
  }

  /// Called by the controller when the drop lands on the wheel, where no global
  /// mouse-up reaches us.
  func finishDragFromDrop() {
    guard isDragActive else { return }
    endDrag()
    onDragEnded?()
  }

  private func endDrag() {
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    isDragActive = false
    shiftWasDown = false
  }

  // MARK: Modifier

  private func handleFlags(_ flags: NSEvent.ModifierFlags, deliveryDelay: TimeInterval?) {
    let entry = ProcessInfo.processInfo.systemUptime
    modifierEventCount += 1
    let down = flags.contains(trigger)
    defer { shiftWasDown = down }

    if down && !shiftWasDown {
      shiftDownAt = entry
      guard isDragActive else { return }
      if let deliveryDelay {
        onNote?(String(format: "Shift down mid-drag (event delivery %.1f ms)", deliveryDelay * 1000))
      } else {
        onNote?("Shift down mid-drag")
      }
      onModifierDown?(entry)
    } else if !down && shiftWasDown && isDragActive {
      let held = entry - shiftDownAt
      onNote?(String(format: "Shift released after %.0f ms (%@)", held * 1000, held <= tapWindow ? "tap" : "hold"))
    }
  }
}

/// Listen-only CGEventTap for flagsChanged. Needs Input Monitoring.
@MainActor
final class ModifierEventTap {
  private let handler: (NSEvent.ModifierFlags) -> Void
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  init(handler: @escaping (NSEvent.ModifierFlags) -> Void) { self.handler = handler }

  func install() -> Bool {
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let raw = event.flags.rawValue
      let box = Unmanaged<ModifierEventTap>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          box.reenable()
        } else {
          box.handler(NSEvent.ModifierFlags(rawValue: UInt(raw)))
        }
      }
      return Unmanaged.passUnretained(event)
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func reenable() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  }

  func remove() {
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    source = nil
    tap = nil
  }
}
