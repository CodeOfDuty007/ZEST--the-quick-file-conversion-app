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
  private static let panelSize = NSSize(width: 340, height: 430)

  nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      NSApp.setActivationPolicy(.accessory)
      setUpStatusItem()
      WheelController.shared.start()
      // Phase 0 only: ask straight away so the system prompts appear without hunting
      // for the icon. Real onboarding (F-10) will explain first.
      WheelController.shared.requestMissingPermissions()
      // The menu-bar icon can be hidden (crowded bar, notch, Menu Bar settings), which
      // makes the app look dead. A window guarantees there is always something to see.
      let firstRun = LaunchAtLogin.isFirstRun
      LaunchAtLogin.shared.enableOnFirstRun()
      if !LaunchAtLogin.shared.shouldStayHidden(firstRun: firstRun) { showWindow() }
      openEditorFromArguments()
    }
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
