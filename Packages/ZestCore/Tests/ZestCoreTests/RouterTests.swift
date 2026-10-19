import UniformTypeIdentifiers
import XCTest

@testable import ZestCore

final class RouterTests: XCTestCase {
  private func cap(
    _ backend: String, _ input: Set<UTType>, _ output: UTType,
    quality: Int = 80, speed: Int = 50, native: Bool = true, lossless: Bool = false
  ) -> Capability {
    Capability(
      backendID: backend, input: input, output: output, quality: quality, speed: speed,
      isNative: native, isLosslessOutput: lossless)
  }

  func testDirectEdgeIsOffered() {
    let router = Router(capabilities: [cap("a", [.heic], .jpeg)])
    let result = router.resolve(inputs: [.heic])
    XCTAssertEqual(result.available.map(\.output), [.jpeg])
    XCTAssertEqual(result.available[0].routes[0].hops, 1)
  }

  func testSameFormatIsRejectedWithReason() {
    let router = Router(capabilities: [cap("a", [.png], .jpeg), cap("a", [.png], .png)])
    let result = router.resolve(inputs: [.png])
    XCTAssertEqual(result.available.map(\.output), [.jpeg])
    XCTAssertEqual(result.rejected, [Rejection(output: .png, reason: .sameFormat)])
  }

  func testNoPathIsRecordedNotSilentlyDropped() {
    let router = Router(capabilities: [cap("a", [.png], .jpeg), cap("a", [.heic], .tiff)])
    let result = router.resolve(inputs: [.png])
    XCTAssertEqual(result.rejected.map(\.output), [.tiff])
    XCTAssertEqual(result.rejected[0].reason, .noPath(input: .png))
  }

  func testTwoHopThroughLosslessIntermediate() {
    let router = Router(capabilities: [
      cap("a", [.heic], .png, lossless: true),
      cap("b", [.png], .tiff),
    ])
    let route = router.bestRoute(from: .heic, to: .tiff)
    XCTAssertEqual(route?.hops, 2)
    XCTAssertEqual(route?.steps.map(\.output), [.png, .tiff])
  }

  func testLossyIntermediateIsNeverUsed() {
    let router = Router(capabilities: [
      cap("a", [.heic], .jpeg, lossless: false),
      cap("b", [.jpeg], .tiff),
    ])
    XCTAssertNil(router.bestRoute(from: .heic, to: .tiff))
  }

  func testNeverMoreThanTwoHops() {
    let router = Router(capabilities: [
      cap("a", [.heic], .png, lossless: true),
      cap("b", [.png], .tiff, lossless: true),
      cap("c", [.tiff], .bmp),
    ])
    XCTAssertNil(router.bestRoute(from: .heic, to: .bmp))
  }

  func testDirectBeatsTwoHopEvenIfLowerQuality() {
    let router = Router(capabilities: [
      cap("direct", [.heic], .tiff, quality: 40),
      cap("a", [.heic], .png, quality: 95, lossless: true),
      cap("b", [.png], .tiff, quality: 95),
    ])
    XCTAssertEqual(router.bestRoute(from: .heic, to: .tiff)?.hops, 1)
  }

  func testRankingPrefersQualityThenNativeThenSpeed() {
    let high = cap("high", [.png], .jpeg, quality: 90, native: false)
    let nativeSlow = cap("nativeSlow", [.png], .jpeg, quality: 80, speed: 10, native: true)
    let nativeFast = cap("nativeFast", [.png], .jpeg, quality: 80, speed: 90, native: true)
    let bundled = cap("bundled", [.png], .jpeg, quality: 80, speed: 99, native: false)

    XCTAssertEqual(
      Router(capabilities: [bundled, high]).bestRoute(from: .png, to: .jpeg)?.steps[0].backendID,
      "high")
    XCTAssertEqual(
      Router(capabilities: [bundled, nativeSlow]).bestRoute(from: .png, to: .jpeg)?.steps[0]
        .backendID, "nativeSlow")
    XCTAssertEqual(
      Router(capabilities: [nativeSlow, nativeFast]).bestRoute(from: .png, to: .jpeg)?.steps[0]
        .backendID, "nativeFast")
  }

  func testMixedSelectionShowsIntersection() {
    let router = Router(capabilities: [
      cap("a", [.png, .heic], .jpeg),
      cap("a", [.png], .tiff),
      cap("a", [.heic], .gif),
    ])
    let result = router.resolve(inputs: [.png, .heic])
    XCTAssertEqual(result.available.map(\.output), [.jpeg])
    XCTAssertEqual(Set(result.rejected.map(\.output)), [.tiff, .gif])
  }

  func testMixedSelectionRoutesAlignWithInputs() {
    let router = Router(capabilities: [
      cap("png", [.png], .jpeg), cap("heic", [.heic], .jpeg),
    ])
    let option = router.resolve(inputs: [.heic, .png]).available[0]
    XCTAssertEqual(option.routes.map { $0.steps[0].backendID }, ["heic", "png"])
  }

  func testUnavailableBackendExplainsItself() {
    let missing = cap("ffmpeg", [.mpeg4Movie], .gif, native: false)
    let router = Router(
      capabilities: [],
      unavailable: [UnavailableCapability(capability: missing, reason: "not installed")])
    let result = router.resolve(inputs: [.mpeg4Movie])
    XCTAssertTrue(result.available.isEmpty)
    XCTAssertEqual(
      result.rejected[0].reason, .backendUnavailable(backend: "ffmpeg", reason: "not installed"))
  }

  func testMissingSecondHopEngineIsNamed() {
    let first = cap("imageio", [.heic], .png, lossless: true)
    let second = cap("cwebp", [.png], .webP, native: false)
    let router = Router(
      capabilities: [first],
      unavailable: [UnavailableCapability(capability: second, reason: "cwebp not found")])
    let rejection = router.resolve(inputs: [.heic]).rejected.first { $0.output == .webP }
    XCTAssertEqual(
      rejection?.reason, .backendUnavailable(backend: "cwebp", reason: "cwebp not found"))
  }

  func testOtherOperationsDoNotRejectSameFormat() {
    let compress = Capability(
      backendID: "a", input: [.jpeg], output: .jpeg, operation: .compress, quality: 70,
      isNative: true)
    let result = Router(capabilities: [compress]).resolve(inputs: [.jpeg], operation: .compress)
    XCTAssertEqual(result.available.map(\.output), [.jpeg])
  }

  func testSubtypeInputsMatchByConformance() {
    let router = Router(capabilities: [cap("a", [.image], .png)])
    XCTAssertNotNil(router.bestRoute(from: .heic, to: .png))
  }

  func testEmptySelectionYieldsNothing() {
    let result = Router(capabilities: [cap("a", [.png], .jpeg)]).resolve(inputs: [])
    XCTAssertTrue(result.available.isEmpty && result.rejected.isEmpty)
  }
}
