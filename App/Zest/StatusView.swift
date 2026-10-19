import AppKit
import SwiftUI

/// The menu-bar popover. On macOS 26 the system gives `.window` menus Liquid Glass
/// automatically; earlier systems get the standard material.
struct StatusView: View {
  @ObservedObject var controller: WheelController
  @ObservedObject var log: SpikeLog = .shared
  @ObservedObject var loginItem: LaunchAtLogin = .shared
  @State private var refresh: Timer?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      Divider()
      permissions
      Divider()
      diagnostics
      Divider()
      logTail
      footer
    }
    .padding(16)
    .frame(width: 340, height: 430, alignment: .topLeading)
    .tint(Theme.accent)
    .onAppear {
      controller.refreshPermissions()
      // Only poll while the popover is on screen; idle means idle.
      refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        MainActor.assumeIsolated { controller.refreshPermissions() }
      }
    }
    .onDisappear {
      refresh?.invalidate()
      refresh = nil
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.pie.fill")
        .font(.system(size: 22))
        .foregroundStyle(Theme.accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("Zest").font(.headline)
        Text("Phase 0 spike · drag a file, tap Shift").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 8) {
      PermissionRow(
        title: "Accessibility", granted: controller.accessibilityGranted,
        request: Permissions.requestAccessibility,
        open: { Permissions.openSettings(.accessibility) })
      PermissionRow(
        title: "Input Monitoring", granted: controller.inputMonitoringGranted,
        request: Permissions.requestInputMonitoring,
        open: { Permissions.openSettings(.inputMonitoring) })
    }
  }

  private var diagnostics: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(
        "Open Zest when I log in",
        isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
      if let error = loginItem.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Picker("Modifier detection", selection: $controller.source) {
        ForEach(DragTrigger.ModifierSource.allCases) { Text($0.rawValue).tag($0) }
      }
      Toggle("Hold latency-critical activity during drags", isOn: $controller.holdsLatencyActivity)
      HStack {
        Text("Drags seen \(controller.dragsSeen)")
        Spacer()
        Text("Modifier events \(controller.modifierEvents)")
        Spacer()
        Text("Last wheel \(controller.lastLatency)")
      }
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  /// Newest first. Scrolls, so wrapped lines never push the footer out of the fixed-size window.
  private var logTail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(log.lines.suffix(30).reversed().enumerated()), id: \.offset) { _, line in
          Text(line).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if log.lines.isEmpty {
          Text("Waiting for a file drag…").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Button("Open log") { NSWorkspace.shared.activateFileViewerSelecting([log.fileURL]) }
      Spacer()
      Button("Quit Zest") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.bordered)
  }
}

private struct PermissionRow: View {
  let title: String
  let granted: Bool
  let request: () -> Void
  let open: () -> Void

  var body: some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(granted ? Color.green : Theme.accent)
      Text(title)
      Spacer()
      if !granted {
        Button("Request", action: request)
        Button("Settings", action: open)
      } else {
        Text("Granted").font(.caption).foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(granted ? "granted" : "not granted")")
  }
}
