import AppKit
import SwiftUI

/// Opens and keeps alive the editor windows. Editors run in the app, not mid-drag, so the
/// wheel hands the file over and closes.
@MainActor
final class EditorWindows {
  static let shared = EditorWindows()

  private var windows: [NSWindow] = []

  /// Returns false if the tool has no editor yet or the file cannot be opened.
  @discardableResult
  func open(toolID: String, file: URL) -> Bool {
    guard let tool = ImageEditorModel.Tool(toolID: toolID),
      let model = ImageEditorModel(source: file, tool: tool)
    else { return false }

    // The view's close action must not keep the window alive, or a closed editor (with
    // its image and undo history) would stay in memory.
    let reference = WeakWindow()
    let view = ImageEditorView(model: model) { reference.window?.close() }
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = []
    let window = NSWindow(contentViewController: controller)
    window.title = "Edit \(file.lastPathComponent)"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 960, height: 680))
    window.center()
    reference.window = window
    windows.append(window)

    // Covers every way a window can close: Save, Cancel and the title-bar button.
    let observer = ObserverBox()
    observer.token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self, weak window, observer] _ in
      MainActor.assumeIsolated {
        if let window {
          self?.windows.removeAll { $0 === window }
          window.contentViewController = nil
        }
        if let token = observer.token { NotificationCenter.default.removeObserver(token) }
      }
    }

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }
}

private final class WeakWindow {
  weak var window: NSWindow?
}

private final class ObserverBox: @unchecked Sendable {
  var token: NSObjectProtocol?
}
