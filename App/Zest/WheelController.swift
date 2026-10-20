import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZestBackends
import ZestCore

/// Wires drag detection, the wheel tree and the engine together.
@MainActor
final class WheelController: ObservableObject {
  static let shared = WheelController()

  @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
  @Published private(set) var inputMonitoringGranted = Permissions.inputMonitoringGranted
  @Published private(set) var modifierEvents = 0
  @Published private(set) var dragsSeen = 0
  @Published private(set) var lastLatency = "–"
  @Published var source: DragTrigger.ModifierSource = .nsEvent {
    didSet { if started, oldValue != source { trigger.start(source: source) } }
  }
  @Published var holdsLatencyActivity = true {
    didSet { trigger.holdsLatencyActivity = holdsLatencyActivity }
  }

  private let log = SpikeLog.shared
  private let trigger = DragTrigger()
  private let model = WheelModel()
  private let catalog = Catalog()
  private var panel: WheelPanel?
  private var started = false
  private var lastDragEnd = ProcessInfo.processInfo.systemUptime

  private struct Session {
    let urls: [URL]
    /// Per output format, one route per file in `urls` order (mixed selections differ per file).
    let convertOptions: [UTType: Resolution.Option]
  }
  private var session: Session?
  /// Bumped per drag so stale callbacks never touch a newer drag.
  private var dragGeneration = 0
  /// True while the drag is over the wheel, so its drop or cancel callback will still arrive.
  private var pointerOverWheel = false
  private var dwellTimer: Timer?

  func start() {
    guard !started else { return }
    started = true

    let panel = WheelPanel(model: model)
    panel.dropView.onEntered = { [weak self] in
      self?.pointerOverWheel = true
      self?.log.log("Panel received draggingEntered")
    }
    panel.dropView.onPointer = { [weak self] dx, dy in self?.pointer(dx: dx, dy: dy) ?? [] }
    // Leaving the panel only clears the hover. The wheel stays up, labels and all, until the
    // drag ends, so dragging past its edge and back never makes it vanish.
    panel.dropView.onExited = { [weak self] in
      self?.pointerOverWheel = false
      self?.model.update { $0.pointerLeft() }
      self?.dwellTimer?.invalidate()
      self?.dwellTimer = nil
    }
    panel.dropView.onDrop = { [weak self] dx, dy, urls in
      self?.handleDrop(dx: dx, dy: dy, urls: urls) ?? false
    }
    panel.dropView.onEnded = { [weak self] in self?.wheelDragEnded() }
    panel.prewarm()
    self.panel = panel

    trigger.onNote = { [weak self] in self?.log.log($0) }
    trigger.onDragBegan = { [weak self] urls, types in self?.dragBegan(urls: urls, types: types) }
    trigger.onDragEnded = { [weak self] in self?.dragEnded() }
    trigger.onModifierDown = { [weak self] t0 in self?.openWheel(t0: t0) }
    trigger.start(source: source)

    refreshPermissions()
    log.log(
      "Zest started. Accessibility=\(accessibilityGranted) InputMonitoring=\(inputMonitoringGranted) engines=\(catalog.backends.map(\.id))"
    )
  }

  /// Triggers the system prompts for anything not yet granted.
  func requestMissingPermissions() {
    if !Permissions.inputMonitoringGranted {
      log.log("Requesting Input Monitoring")
      Permissions.requestInputMonitoring()
    }
    if !Permissions.accessibilityGranted {
      log.log("Requesting Accessibility")
      Permissions.requestAccessibility()
    }
  }

  func refreshPermissions() {
    accessibilityGranted = Permissions.accessibilityGranted
    inputMonitoringGranted = Permissions.inputMonitoringGranted
    modifierEvents = trigger.modifierEventCount
  }

  // MARK: Drag lifecycle

  private func dragBegan(urls: [URL], types: [String]) {
    dragsSeen += 1
    // Start clean, and make sure the early returns below cannot leave an old session or
    // wheel active from the previous drag.
    dragGeneration += 1
    closeWheel(reason: "new drag started")
    pointerOverWheel = false
    session = nil
    model.clear()

    let kinds = urls.map { ContentSniffer.type(ofFileAt: $0) }
    log.log(
      "File drag: \(urls.count) file(s) \(urls.first?.lastPathComponent ?? "") [\(kinds.map { $0?.identifier ?? "?" }.joined(separator: ", "))] pasteboard=\(types.prefix(4).joined(separator: ","))"
    )

    guard let inputs = kinds as? [UTType] else {
      log.log("Wheel skipped: could not identify every file")
      return
    }
    // Types cannot tell a still TIFF from a multi-page one, so check the files themselves and
    // dim the editors rather than let a drop fail silently.
    var dimmed: [String: String] = [:]
    if !urls.allSatisfy(ImageEditorModel.canEdit) {
      for tool in catalog.router.tools where tool.status == .opensEditor {
        dimmed[tool.id] = "Multi-page or animated images can't be edited yet."
      }
    }
    let tree = WheelTree.build(router: catalog.router, inputs: inputs, dimmed: dimmed)
    guard !tree.children.isEmpty else {
      log.log("Wheel skipped: nothing applies to this selection")
      return
    }
    let options = Dictionary(
      uniqueKeysWithValues: catalog.router.resolve(inputs: inputs).available.map { ($0.output, $0) })
    model.configure(tree: tree, urls: urls)
    session = Session(urls: urls, convertOptions: options)
    log.log("Wheel ready: \(tree.children.map(\.title).joined(separator: " · "))")
  }

  private func dragEnded() {
    lastDragEnd = ProcessInfo.processInfo.systemUptime
    refreshPermissions()
    guard model.isOpen else {
      session = nil
      return
    }
    // The global mouse-up can arrive before the drop is delivered to the wheel. If the
    // pointer is over the wheel, the drop or cancel callback (`wheelDragEnded`) tears
    // down; a timer would race a slow drop. If it never reached the wheel, no drop can
    // come, so close now.
    if !pointerOverWheel {
      closeWheel(reason: "mouse up")
      session = nil
    }
  }

  /// The drag session ended over the wheel. `performDragOperation` has already run if
  /// there was a drop, and `handleDrop` clears the session itself.
  private func wheelDragEnded() {
    pointerOverWheel = false
    closeWheel(reason: "drag ended over wheel")
    session = nil
  }

  // MARK: Wheel

  private func openWheel(t0: TimeInterval) {
    guard session != nil, !model.isOpen, let panel else { return }
    let idle = t0 - lastDragEnd
    model.resetToRoot()
    panel.present(at: NSEvent.mouseLocation)
    let t1 = ProcessInfo.processInfo.systemUptime
    lastLatency = String(format: "%.1f ms", (t1 - t0) * 1000)
    log.log(
      String(
        format: "Wheel shown: %.1f ms from modifier handler to orderFront+display (idle %.0f s, activity=%@)",
        (t1 - t0) * 1000, idle, holdsLatencyActivity ? "on" : "off"))
  }

  private func closeWheel(reason: String) {
    guard model.isOpen else { return }
    dwellTimer?.invalidate()
    dwellTimer = nil
    panel?.dismiss()
    log.log("Wheel closed (\(reason))")
  }

  // MARK: Pointer

  /// Called for every pointer position while a drag is over the wheel. Returns `.copy`
  /// only over an enabled leaf that has settled, so a drop anywhere else is refused.
  private func pointer(dx: Double, dy: Double) -> NSDragOperation {
    let geometry = model.geometry
    let hit = geometry.hit(dx: dx, dy: dy)
    if hit == .outside {
      model.update { $0.pointerLeft() }
      dwellTimer?.invalidate()
      dwellTimer = nil
      return []
    }

    let now = ProcessInfo.processInfo.systemUptime
    model.update { $0.pointerMoved(hit: hit, dx: dx, dy: dy, now: now) }
    scheduleDwell()
    return model.navigator?.droppableNode(hit: hit, dx: dx, dy: dy) != nil ? .copy : []
  }

  /// Fires the hold-to-open step. A timer, not drag callbacks: they stop arriving while the
  /// pointer is still, which is exactly when the user is holding.
  private func scheduleDwell() {
    dwellTimer?.invalidate()
    dwellTimer = nil
    guard let start = model.navigator?.dwellStart else { return }
    let remaining = max(start + model.dwell - ProcessInfo.processInfo.systemUptime, 0)
    let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.dwellFired() }
    }
    // Common modes: a drag session runs the loop in event-tracking mode, where default-mode
    // timers do not fire.
    RunLoop.main.add(timer, forMode: .common)
    dwellTimer = timer
  }

  private func dwellFired() {
    let now = ProcessInfo.processInfo.systemUptime
    let effect = model.update { $0.tick(now: now) } ?? nil
    if let effect {
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      log.log(
        "Wheel \(effect == .descended ? "opened" : "went back to") \(model.breadcrumb.last ?? "root")")
    }
    scheduleDwell()
  }

  // MARK: Drop

  private func handleDrop(dx: Double, dy: Double, urls: [URL]) -> Bool {
    let hit = model.geometry.hit(dx: dx, dy: dy)
    guard let session, let node = model.navigator?.droppableNode(hit: hit, dx: dx, dy: dy) else {
      log.log("Drop refused: not on a ready option")
      return false
    }
    log.log("Drop on \(node.title): \(session.urls.map(\.lastPathComponent).joined(separator: ", "))")

    let pipeline = catalog.pipeline
    let router = catalog.router
    let sources = session.urls
    let options = session.convertOptions
    closeWheel(reason: "dropped")
    self.session = nil
    trigger.finishDragFromDrop()

    Task { [weak self] in
      var outputs: [URL] = []
      var failures = 0
      var problems: [String] = []

      switch node.action {
      case .convert(let type):
        guard let option = options[type], option.routes.count == sources.count else {
          self?.log.log("FAILED: no route to \(node.title)")
          self?.present(problems: ["no route to \(node.title)"], title: node.title, produced: 0)
          return
        }
        // All files convert at once, a few at a time; one failing never stops the rest.
        let batch = await pipeline.runBatch(inputs: sources, routes: option.routes)
        for item in batch {
          switch item.result {
          case .success(let urls):
            outputs += urls
            for out in urls {
              self?.log.log("Converted \(item.input.lastPathComponent) → \(out.lastPathComponent)")
            }
          case .failure(let error):
            failures += 1
            problems.append("\(item.input.lastPathComponent): \(error.localizedDescription)")
            self?.log.log("FAILED \(item.input.lastPathComponent): \(error.localizedDescription)")
          }
        }

      case .tool(let id):
        guard let tool = router.tools.first(where: { $0.id == id }) else {
          self?.log.log("FAILED: unknown tool \(id)")
          self?.present(problems: ["unknown tool \(id)"], title: node.title, produced: 0)
          return
        }
        // Editors open a window; everything else runs straight through the pipeline.
        if tool.status == .opensEditor {
          if let file = sources.first, EditorWindows.shared.open(toolID: id, file: file) {
            self?.log.log("Opened \(node.title) editor for \(file.lastPathComponent)")
          } else {
            self?.log.log("FAILED: could not open the \(node.title) editor")
            self?.present(problems: sources.map { "\($0.lastPathComponent): could not open the \(node.title) editor" }, title: node.title, produced: 0)
          }
          return
        }
        do {
          let report = try await pipeline.runTool(tool, inputs: sources)
          outputs = report.published
          for url in report.published { self?.log.log("\(node.title) → \(url.lastPathComponent)") }
          for skip in report.skipped {
            problems.append("\(skip.input.lastPathComponent): \(skip.reason)")
            self?.log.log("Skipped \(skip.input.lastPathComponent): \(skip.reason)")
          }
        } catch {
          failures += 1
          problems += sources.map { "\($0.lastPathComponent): \(error.localizedDescription)" }
          self?.log.log("FAILED \(node.title): \(error.localizedDescription)")
        }

      case .branch:
        break
      }

      // Phase 0 question: Finder must never move or delete the source when we return .copy.
      let intact = sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
      self?.log.log("Source files still present after drop: \(intact) (\(failures) failure(s))")
      if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
      if !problems.isEmpty { self?.present(problems: problems, title: node.title, produced: outputs.count) }
    }
    return true
  }

  /// Nothing may fail or be skipped without the user seeing why; the log is not enough.
  private func present(problems: [String], title: String, produced: Int) {
    let alert = NSAlert()
    alert.messageText = produced == 0 ? "\(title) did nothing" : "\(title) finished with problems"
    alert.informativeText = "\(problems.count) file\(problems.count == 1 ? "" : "s") not done:"
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
    text.string = problems.joined(separator: "\n")
    text.isEditable = false
    text.font = .systemFont(ofSize: 12)
    let scroll = NSScrollView(frame: text.frame)
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    alert.accessoryView = scroll
    alert.alertStyle = .warning
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
