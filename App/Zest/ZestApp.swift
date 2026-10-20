import AppKit
import SwiftUI

@main
struct ZestApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // The menu-bar item is an NSStatusItem owned by the delegate; SwiftUI needs a scene.
    Settings { EmptyView() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var window: NSWindow?
  /// Set when a login launch keeps the window hidden; the reopen the system may send
  /// in the first moments after that launch is not the user.
  private var hiddenLaunchAt: TimeInterval?
  private static let panelSize = NSSize(width: 340, height: 430)

  nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      // Two copies at once each draw their own wheel at the same level, so a stale build
      // shows through the current one. The first copy keeps running; later ones hand over.
      // `--edit` launches exist to open an editor in a fresh process, so they are exempt
      // from the guard and never start a wheel of their own.
      let editorOnly = CommandLine.arguments.contains("--edit")
      if !editorOnly, let other = Self.otherRunningInstance() {
        other.activate()
        NSApp.terminate(nil)
        return
      }
      if !editorOnly { Self.registerAsMain() }
      NSApp.setActivationPolicy(.accessory)
      setUpStatusItem()
      if !editorOnly { WheelController.shared.start() }
      // Phase 0 only: ask straight away so the system prompts appear without hunting
      // for the icon. Real onboarding (F-10) will explain first.
      if !editorOnly { WheelController.shared.requestMissingPermissions() }
      // The menu-bar icon can be hidden (crowded bar, notch, Menu Bar settings), which
      // makes the app look dead. A window guarantees there is always something to see.
      let firstRun = LaunchAtLogin.isFirstRun
      LaunchAtLogin.shared.enableOnFirstRun()
      if LaunchAtLogin.shared.shouldStayHidden(firstRun: firstRun) {
        // Monotonic clock: wall time can jump at login when the network syncs it.
        hiddenLaunchAt = ProcessInfo.processInfo.systemUptime
      } else {
        showWindow()
      }
      openEditorFromArguments()
    }
  }

  private static func otherRunningInstance() -> NSRunningApplication? {
    guard let id = Bundle.main.bundleIdentifier else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    func running() -> NSRunningApplication? {
      // Only a process that registered itself as the main app counts: an editor opened with
      // `--edit` shares the bundle id but must never make the main app quit.
      let main = Self.registeredMainPID()
      return NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first {
          $0.processIdentifier != me && $0.processIdentifier == main && !$0.isTerminated
            && ($0.launchDate ?? .distantPast) <= (NSRunningApplication.current.launchDate ?? .distantFuture)
        }
    }
    // `make launch` kills the old copy and opens the new one straight away; give a copy that
    // is on its way out a moment to finish quitting instead of mistaking it for a duplicate.
    for _ in 0..<20 {
      guard running() != nil else { return nil }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return running()
  }

  private static var lockURL: URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("org.zest.main.pid")
  }

  private static func registeredMainPID() -> pid_t? {
    (try? String(contentsOf: lockURL, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  private static func registerAsMain() {
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: lockURL, atomically: true, encoding: .utf8)
  }

  /// `Zest --edit crop.image /path/to/file` opens an editor directly (smoke tests, scripts).
  private func openEditorFromArguments() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--edit"), arguments.count > flag + 2 else { return }
    let opened = EditorWindows.shared.open(
      toolID: arguments[flag + 1], file: URL(fileURLWithPath: arguments[flag + 2]))
    SpikeLog.shared.log("--edit \(arguments[flag + 1]): \(opened ? "opened" : "could not open")")
  }

  /// Opening the app again (Finder, Launchpad) brings the window back.
  nonisolated func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    MainActor.assumeIsolated {
      if let start = hiddenLaunchAt, ProcessInfo.processInfo.systemUptime - start < 3 { return }
      showWindow()
    }
    return true
  }

  private func showWindow() {
    if window == nil {
      let controller = NSHostingController(rootView: StatusView(controller: .shared))
      // Fixed size: letting SwiftUI resize the window as the log text changes sends
      // AppKit into an endless constraint-update loop and crashes the app.
      controller.sizingOptions = []
      let window = NSWindow(contentViewController: controller)
      window.setContentSize(Self.panelSize)
      window.title = "Zest"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Zest")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Zest"
      button.target = self
      button.action = #selector(togglePopover(_:))
    }
    statusItem = item

    popover.behavior = .transient
    let controller = NSHostingController(rootView: StatusView(controller: .shared))
    controller.sizingOptions = []
    popover.contentViewController = controller
    popover.contentSize = Self.panelSize
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }
}
