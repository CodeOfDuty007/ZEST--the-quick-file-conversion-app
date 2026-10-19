import XCTest

@testable import ZestCore

final class WheelGeometryTests: XCTestCase {
  private let six = WheelGeometry(wedgeCount: 6)

  func testCentreIsDeadZone() {
    XCTAssertEqual(six.hit(dx: 0, dy: 0), .deadZone)
    XCTAssertEqual(six.hit(dx: 30, dy: 30), .deadZone)
  }

  func testBeyondOuterRadiusIsOutside() {
    XCTAssertEqual(six.hit(dx: 0, dy: 141), .outside)
    XCTAssertEqual(six.hit(dx: 100, dy: 100), .outside)
  }

  /// A point at `degrees` clockwise from 12 o'clock, `radius` from the centre.
  private func point(_ radius: Double, _ degrees: Double) -> (dx: Double, dy: Double) {
    (radius * sin(degrees * .pi / 180), radius * cos(degrees * .pi / 180))
  }

  func testButtonCentresHitTheirOwnWedgeClockwiseFromTop() {
    let ring = six.buttonRingRadius
    for index in 0..<6 {
      let p = point(ring, Double(index) * 60)
      XCTAssertEqual(six.hit(dx: p.dx, dy: p.dy), .wedge(index), "button \(index)")
    }
  }

  func testDropBeyondTheButtonButInsideTheSectorIsNotATarget() {
    // 135 pt straight up is inside wedge 0's sector but past the 66 pt button at 94 pt.
    XCTAssertEqual(six.hit(dx: 0, dy: 135), .gap)
    // Between two buttons at the same radius.
    let between = point(six.buttonRingRadius, 30)
    XCTAssertEqual(six.hit(dx: between.dx, dy: between.dy), .gap)
  }

  func testButtonEdgeIsATargetWithSlopAndNothingBeyond() {
    let ring = six.buttonRingRadius
    XCTAssertEqual(six.hit(dx: 0, dy: ring + 33), .wedge(0))
    XCTAssertEqual(six.hit(dx: 0, dy: ring + 38), .wedge(0))  // inside the 6 pt slop
    XCTAssertEqual(six.hit(dx: 0, dy: ring + 40), .gap)
  }

  func testEveryButtonIsReachableForEveryWedgeCount() {
    for count in 1...8 {
      let geometry = WheelGeometry(wedgeCount: count)
      for index in 0..<count {
        let p = point(geometry.buttonRingRadius, Double(index) * 360 / Double(count))
        XCTAssertEqual(geometry.hit(dx: p.dx, dy: p.dy), .wedge(index), "\(count) wedges, \(index)")
      }
    }
  }

  func testEveryPointInTheRingIsAWedgeOrAGapNeverOutside() {
    for count in 1...8 {
      let geometry = WheelGeometry(wedgeCount: count)
      for degrees in stride(from: 0.0, to: 360.0, by: 1.0) {
        let p = point(100, degrees)
        switch geometry.hit(dx: p.dx, dy: p.dy) {
        case .wedge(let index): XCTAssertTrue((0..<count).contains(index))
        case .gap: break
        default: XCTFail("\(count) @ \(degrees)")
        }
      }
    }
  }

  func testWedgeCountIsCappedAtEight() {
    XCTAssertEqual(WheelGeometry(wedgeCount: 20).wedgeCount, 8)
    XCTAssertEqual(WheelGeometry(wedgeCount: -1).wedgeCount, 0)
  }

  func testEmptyWheelHasNoWedges() {
    let empty = WheelGeometry(wedgeCount: 0)
    XCTAssertEqual(empty.hit(dx: 0, dy: 100), .outside)
  }

  func testCloseHappensOnlyPastTheMargin() {
    XCTAssertFalse(six.shouldClose(dx: 0, dy: 145))
    XCTAssertTrue(six.shouldClose(dx: 0, dy: 153))
  }

  func testSingleButtonSitsAtTopAndTheRestOfTheRingIsGap() {
    let one = WheelGeometry(wedgeCount: 1)
    XCTAssertEqual(one.hit(dx: 0, dy: one.buttonRingRadius), .wedge(0))
    XCTAssertEqual(one.hit(dx: 0, dy: -100), .gap)
  }
}
