import UniformTypeIdentifiers
import XCTest
import ZestCore

@testable import ZestBackends

final class FFmpegBackendTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-ffmpeg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  func testMissingFFmpegIsExplainedNotHidden() {
    // Point detection nowhere by testing the declared list directly.
    let declared = FFmpegBackend.declaredCapabilities()
    let router = Router(
      capabilities: [],
      unavailable: declared.map { UnavailableCapability(capability: $0, reason: "missing") })
    let result = router.resolve(inputs: [.mpeg4Movie])
    XCTAssertTrue(result.available.isEmpty)
    XCTAssertTrue(result.rejected.contains { $0.output == .gif })
  }

  func testCancelBeforeLaunchStillStopsTheProcess() async throws {
    let sleep = URL(fileURLWithPath: "/bin/sleep")
    let task = Task { try await ProcessRunner.run(sleep, arguments: ["30"]) }
    task.cancel()  // lands before or just after launch; both must stop the child
    let started = Date()
    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testWMAIsDecodeOnly() {
    let declared = FFmpegBackend.declaredCapabilities()
    XCTAssertFalse(declared.contains { $0.output == Formats.wma })
    XCTAssertTrue(declared.contains { $0.input.contains(Formats.wma) })
  }

  func testWAVToMP3GoldenPath() async throws {
    guard let ffmpeg = FFmpegBackend.detect() else { throw XCTSkip("FFmpeg not installed") }
    let wav = dir.appendingPathComponent("tone.wav")
    try await ProcessRunner.run(
      ffmpeg.executable,
      arguments: ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", wav.path])

    let router = Router(capabilities: ffmpeg.capabilities())
    let route = try XCTUnwrap(router.bestRoute(from: .wav, to: .mp3))
    let out = try await JobPipeline(backends: [ffmpeg]).run(input: wav, route: route)
    XCTAssertEqual(out.lastPathComponent, "tone.mp3")
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .mp3)
  }

  func testCorruptInputFailsWithReadableError() async throws {
    guard let ffmpeg = FFmpegBackend.detect() else { throw XCTSkip("FFmpeg not installed") }
    let bad = dir.appendingPathComponent("bad.wav")
    try Data("definitely not audio".utf8).write(to: bad)
    let router = Router(capabilities: ffmpeg.capabilities())
    let route = try XCTUnwrap(router.bestRoute(from: .wav, to: .mp3))
    do {
      _ = try await JobPipeline(backends: [ffmpeg]).run(input: bad, route: route)
      XCTFail("expected failure")
    } catch let error as BackendError {
      XCTAssertNotNil(error.errorDescription)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["bad.wav"])
  }
}
