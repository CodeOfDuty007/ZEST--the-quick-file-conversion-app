import AppKit
import ApplicationServices
import CoreGraphics

/// Permission checks and prompts. Phase 0 records which API triggers which prompt.
enum Permissions {
  static var accessibilityGranted: Bool { AXIsProcessTrusted() }
  static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

  static func requestAccessibility() {
    // kAXTrustedCheckOptionPrompt is a mutable global under Swift 6, so use its value.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func requestInputMonitoring() {
    _ = CGRequestListenEventAccess()
  }

  enum Pane: String {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"
  }

  static func openSettings(_ pane: Pane) {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    NSWorkspace.shared.open(url)
  }
}
