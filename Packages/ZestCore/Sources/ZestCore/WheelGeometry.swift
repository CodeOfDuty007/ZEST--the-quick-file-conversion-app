import Foundation

/// Wedge hit-testing as pure maths: angle and radius from the centre. No AppKit, so
/// it is unit-tested without a window.
///
/// Wedge 0 is centred at 12 o'clock and wedges run clockwise. Points are relative to
/// the wheel centre with y pointing up (AppKit's convention).
public struct WheelGeometry: Sendable, Equatable {
  public static let maxWedges = 8

  public enum Hit: Sendable, Equatable {
    case deadZone
    case wedge(Int)
    /// Inside the ring but between buttons: not a drop target.
    case gap
    case outside
  }

  public let outerRadius: Double
  public let deadZoneRadius: Double
  public let wedgeCount: Int
  /// Extra distance past the ring before the wheel closes, so a jittery edge
  /// does not flicker it shut.
  public let closeMargin: Double
  /// Radius of each round button, so a drop only counts on or just beside a button.
  public let buttonRadius: Double
  /// Extra reach around a button, so aiming does not need pixel precision.
  public let hitSlop: Double

  public init(
    outerRadius: Double = 140,
    deadZoneRadius: Double = 48,
    wedgeCount: Int,
    closeMargin: Double = 12,
    buttonRadius: Double = 33,
    hitSlop: Double = 6
  ) {
    self.outerRadius = outerRadius
    self.deadZoneRadius = deadZoneRadius
    self.wedgeCount = min(max(wedgeCount, 0), Self.maxWedges)
    self.closeMargin = closeMargin
    self.buttonRadius = buttonRadius
    self.hitSlop = hitSlop
  }

  /// Distance from the wheel centre to the middle of every button.
  public var buttonRingRadius: Double { (deadZoneRadius + outerRadius) / 2 }

  /// Angle each wedge spans, in radians.
  public var sweep: Double { wedgeCount > 0 ? 2 * .pi / Double(wedgeCount) : 0 }

  public func hit(dx: Double, dy: Double) -> Hit {
    let radius = (dx * dx + dy * dy).squareRoot()
    if radius < deadZoneRadius { return .deadZone }
    if radius > outerRadius || wedgeCount == 0 { return .outside }
    let index = wedgeIndex(dx: dx, dy: dy)
    // Only the button itself (plus a little slop) is a target, not its whole sector.
    let angle = centreAngle(of: index)
    let bx = buttonRingRadius * sin(angle), by = buttonRingRadius * cos(angle)
    let distance = ((dx - bx) * (dx - bx) + (dy - by) * (dy - by)).squareRoot()
    return distance <= buttonRadius + hitSlop ? .wedge(index) : .gap
  }

  /// True once the pointer has moved far enough out that the wheel should close.
  public func shouldClose(dx: Double, dy: Double) -> Bool {
    (dx * dx + dy * dy).squareRoot() > outerRadius + closeMargin
  }

  /// Angle of a wedge's centre, clockwise from 12 o'clock, in radians.
  public func centreAngle(of index: Int) -> Double { Double(index) * sweep }

  private func wedgeIndex(dx: Double, dy: Double) -> Int {
    var angle = atan2(dx, dy)  // clockwise from 12 o'clock
    if angle < 0 { angle += 2 * .pi }
    return Int((angle + sweep / 2) / sweep) % wedgeCount
  }
}
