import Foundation

/// The hold-to-descend state machine. Pure, with time passed in, so it is unit-tested
/// without a window or a timer.
///
/// During a drag the user cannot click, so navigation is dwell-based: holding over a
/// branch enters it, holding over the centre goes back up one level.
public struct WheelNavigator: Sendable {
  public enum Target: Sendable, Equatable {
    case child(Int)
    case centre
  }

  public enum Effect: Sendable, Equatable {
    case descended
    case ascended
  }

  public static let defaultDwell: TimeInterval = 0.55
  /// After a level change the pointer must move this far, or reach a different target,
  /// before dwell restarts or a drop counts. Otherwise a child branch under the pointer
  /// would be entered immediately and the user would fall through several levels.
  public static let settleDistance = 12.0

  public private(set) var path: [WheelNode]
  public let dwell: TimeInterval
  public private(set) var hovered: Target?
  public private(set) var dwellStart: TimeInterval?

  private struct Anchor {
    let dx: Double
    let dy: Double
    /// Unknown until the first pointer event after the level change.
    var target: Target??
  }
  private var anchor: Anchor?
  private var lastDx = 0.0
  private var lastDy = 0.0

  public init(root: WheelNode, dwell: TimeInterval = WheelNavigator.defaultDwell) {
    self.path = [root]
    self.dwell = dwell
  }

  public var current: WheelNode { path[path.count - 1] }
  public var canGoBack: Bool { path.count > 1 }
  public var breadcrumb: [String] { path.dropFirst().map(\.title) }

  /// What the pointer is dwelling on, if a hold is in progress.
  public var dwellTarget: Target? { dwellStart == nil ? nil : hovered }

  public func dwellProgress(now: TimeInterval) -> Double {
    guard let dwellStart else { return 0 }
    return min(max((now - dwellStart) / dwell, 0), 1)
  }

  public mutating func reset() {
    path = [path[0]]
    hovered = nil
    dwellStart = nil
    anchor = nil
  }

  public mutating func pointerLeft() {
    hovered = nil
    dwellStart = nil
  }

  /// Feed every pointer position. Returns nothing: level changes come from `tick`.
  public mutating func pointerMoved(hit: WheelGeometry.Hit, dx: Double, dy: Double, now: TimeInterval) {
    lastDx = dx
    lastDy = dy
    let target = self.target(for: hit)

    if var pending = anchor {
      if pending.target == nil { pending.target = .some(target) }  // first event after the change
      let moved = hypot(dx - pending.dx, dy - pending.dy) > Self.settleDistance
      let sameTarget = pending.target == .some(target)
      anchor = (moved || !sameTarget) ? nil : pending
    }

    if target != hovered {
      hovered = target
      dwellStart = nil
    }
    if anchor == nil, dwellStart == nil, let target, canDwell(on: target) {
      dwellStart = now
    }
  }

  /// Call when the dwell timer fires. Descends or ascends if the hold completed.
  @discardableResult
  public mutating func tick(now: TimeInterval) -> Effect? {
    guard let start = dwellStart, let hovered, now - start >= dwell else { return nil }
    switch hovered {
    case .child(let index) where current.children.indices.contains(index):
      path.append(current.children[index])
      settleAfterChange()
      return .descended
    case .centre where canGoBack:
      path.removeLast()
      settleAfterChange()
      return .ascended
    default:
      return nil
    }
  }

  /// The leaf a drop here would run, or nil if the spot is not a valid, settled target.
  public func droppableNode(hit: WheelGeometry.Hit, dx: Double, dy: Double) -> WheelNode? {
    guard case .child(let index) = target(for: hit), current.children.indices.contains(index)
    else { return nil }
    if let pending = anchor {
      let moved = hypot(dx - pending.dx, dy - pending.dy) > Self.settleDistance
      let unresolved = pending.target == nil
      if unresolved || (!moved && pending.target == .some(.child(index))) { return nil }
    }
    let node = current.children[index]
    return node.isDroppable ? node : nil
  }

  /// The node under the pointer, droppable or not, for hover highlighting.
  public func hoveredNode() -> WheelNode? {
    guard case .child(let index) = hovered, current.children.indices.contains(index) else {
      return nil
    }
    return current.children[index]
  }

  // MARK: Private

  private func target(for hit: WheelGeometry.Hit) -> Target? {
    switch hit {
    case .wedge(let index): return current.children.indices.contains(index) ? .child(index) : nil
    case .deadZone: return canGoBack ? .centre : nil
    case .gap, .outside: return nil
    }
  }

  private func canDwell(on target: Target) -> Bool {
    switch target {
    case .child(let index):
      guard current.children.indices.contains(index) else { return false }
      let node = current.children[index]
      return node.isBranch && node.isEnabled
    case .centre:
      return canGoBack
    }
  }

  private mutating func settleAfterChange() {
    hovered = nil
    dwellStart = nil
    anchor = Anchor(dx: lastDx, dy: lastDy, target: nil)
  }
}
