import AppKit
import SwiftUI
import ZestCore

/// What the wheel is showing right now. The navigator owns the tree position; this class
/// republishes it for SwiftUI and keeps the hit-test geometry in step with the ring.
@MainActor
final class WheelModel: ObservableObject {
  @Published private(set) var nodes: [WheelNode] = []
  /// Changes whenever the ring changes, so SwiftUI can animate between levels.
  @Published private(set) var levelID = WheelTree.root
  @Published private(set) var hovered: Int?
  @Published private(set) var dwellTarget: WheelNavigator.Target?
  @Published private(set) var hoveredNode: WheelNode?
  @Published private(set) var canGoBack = false
  @Published private(set) var breadcrumb: [String] = []
  @Published var isOpen = false
  @Published private(set) var fileCount = 0
  @Published private(set) var icon: NSImage?

  private(set) var geometry = WheelGeometry(wedgeCount: 0)
  private(set) var navigator: WheelNavigator?

  var dwell: TimeInterval { navigator?.dwell ?? WheelNavigator.defaultDwell }

  func configure(tree: WheelNode, urls: [URL]) {
    navigator = WheelNavigator(root: tree)
    levelID = ""  // force the geometry to be rebuilt for the first ring
    fileCount = urls.count
    icon = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
    sync()
  }

  func resetToRoot() {
    navigator?.reset()
    levelID = ""
    sync()
  }

  /// Applies a change to the navigator and republishes. Returns whatever the change returned.
  @discardableResult
  func update<T>(_ change: (inout WheelNavigator) -> T) -> T? {
    guard var navigator else { return nil }
    let result = change(&navigator)
    self.navigator = navigator
    sync()
    return result
  }

  func sync() {
    guard let navigator else { return }
    let current = navigator.current
    if current.id != levelID {
      levelID = current.id
      geometry = WheelGeometry(
        wedgeCount: current.children.count, buttonRadius: Double(WheelView.bubble) / 2)
    }
    if nodes != current.children { nodes = current.children }
    if case .child(let index) = navigator.hovered { hovered = index } else { hovered = nil }
    dwellTarget = navigator.dwellTarget
    hoveredNode = navigator.hoveredNode()
    canGoBack = navigator.canGoBack
    breadcrumb = navigator.breadcrumb
  }

  func clear() {
    navigator = nil
    nodes = []
    hovered = nil
    dwellTarget = nil
    hoveredNode = nil
    levelID = WheelTree.root
  }
}
