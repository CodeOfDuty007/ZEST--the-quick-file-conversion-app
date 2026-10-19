import AppKit
import Foundation
import ServiceManagement

/// Keeps Zest running across restarts through a login item (SMAppService, macOS 13+).
/// New installs opt in once; after that the toggle in the window is the only authority.
@MainActor
final class LaunchAtLogin: ObservableObject {
  static let shared = LaunchAtLogin()

  private static let decidedKey = "launchAtLoginDecided"

  @Published private(set) var isEnabled = false
  @Published private(set) var lastError: String?

  private let service = SMAppService.mainApp

  init() {
    refresh()
    SpikeLog.shared.log("Login item status: \(service.status.rawValue) (1 = enabled, 2 = needs approval)")
  }

  func refresh() {
    isEnabled = service.status == .enabled
    if service.status == .requiresApproval {
      lastError = "Allow Zest in System Settings > General > Login Items."
    }
  }

  /// Registers once on first run from an Applications folder. A development build in
  /// DerivedData must not claim the login item.
  func enableOnFirstRun() {
    guard !UserDefaults.standard.bool(forKey: Self.decidedKey), Self.isInstalled else {
      refresh()
      return
    }
    UserDefaults.standard.set(true, forKey: Self.decidedKey)
    set(true)
  }

  func set(_ enabled: Bool) {
    UserDefaults.standard.set(true, forKey: Self.decidedKey)
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }

  /// True when the app lives in /Applications or ~/Applications.
  static var isInstalled: Bool {
    let path = Bundle.main.bundleURL.path
    return path.hasPrefix("/Applications/")
      || path.hasPrefix(NSHomeDirectory() + "/Applications/")
  }

  /// True when the system started Zest as a login item, so it should sit in the menu bar
  /// rather than open its window. Read during launch, while the launch event is current.
  static var launchedAtLogin: Bool {
    let event = NSAppleEventManager.shared().currentAppleEvent
    return event?.eventID == AEEventID(kAEOpenApplication)
      && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        == OSType(keyAELaunchedAsLogInItem)
  }

  /// Whether this launch should stay in the menu bar. The login-launch Apple event is not
  /// always delivered to SMAppService launches, so a launch in the first two minutes after
  /// boot also counts, unless it is the first run ever (the user just installed Zest and
  /// needs to see it).
  static func shouldStayHidden(firstRun: Bool) -> Bool {
    if launchedAtLogin { return true }
    return !firstRun && ProcessInfo.processInfo.systemUptime < 120
  }

  static var isFirstRun: Bool { !UserDefaults.standard.bool(forKey: decidedKey) }
}
