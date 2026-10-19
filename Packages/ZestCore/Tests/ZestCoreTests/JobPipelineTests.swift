import CryptoKit
import UniformTypeIdentifiers
import XCTest

@testable import ZestCore

private struct FakeBackend: Backend {
  enum Mode: Sendable { case ok, empty, fail, none, slow }
  let id: String
  let mode: Mode

  func capabilities() -> [Capability] { [] }

  func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    let ext = Formats.fileExtension(for: job.capability.output)
    let out = job.outputDirectory.appendingPathComponent("result.\(ext)")
    switch mode {
    case .ok:
      try Data("converted".utf8).write(to: out)
      return [out]
    case .empty:
      try Data().write(to: out)
      return [out]
    case .fail:
      try Data("partial".utf8).write(to: out)
      throw NSError(domain: "fake", code: 1)
    case .none:
      return []
    case .slow:
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return [out]
    }
  }
}

final class JobPipelineTests: XCTestCase {
  private var dir: URL!
  private var temp: URL!

  override func setUpWithError() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-tests-\(UUID().uuidString)")
    dir = base.appendingPathComponent("files")
    temp = base.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
  }

  private func makeSource(_ name: String = "photo.png") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data("original bytes".utf8).write(to: url)
    return url
  }

  private func route(_ output: UTType = .jpeg, backend: String = "fake") -> Route {
    Route(steps: [
      Capability(backendID: backend, input: [.png], output: output, quality: 80, isNative: true)
    ])
  }

  private func pipeline(_ mode: FakeBackend.Mode) -> JobPipeline {
    JobPipeline(backends: [FakeBackend(id: "fake", mode: mode)], tempRoot: temp)
  }

  private func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  private func tempLeftovers() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
  }

  func testSuccessWritesBesideOriginalAndLeavesSourceUntouched() async throws {
    let source = try makeSource()
    let before = try hash(source)
    let out = try await pipeline(.ok).run(input: source, route: route())
    XCTAssertEqual(out.lastPathComponent, "photo.jpg")
    XCTAssertEqual(out.deletingLastPathComponent().path, dir.path)
    XCTAssertEqual(try hash(source), before)
    XCTAssertTrue(tempLeftovers().isEmpty)
    // The staging file must not outlive the job.
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
      ["photo.jpg", "photo.png"])
  }

  func testNeverOverwritesExistingOutput() async throws {
    let source = try makeSource()
    let existing = dir.appendingPathComponent("photo.jpg")
    try Data("keep me".utf8).write(to: existing)
    let out = try await pipeline(.ok).run(input: source, route: route())
    XCTAssertEqual(out.lastPathComponent, "photo 2.jpg")
    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
  }

  func testFailureLeavesNothingBehind() async throws {
    let source = try makeSource()
    let before = try hash(source)
    do {
      _ = try await pipeline(.fail).run(input: source, route: route())
      XCTFail("expected failure")
    } catch {}
    XCTAssertEqual(try hash(source), before)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["photo.png"])
    XCTAssertTrue(tempLeftovers().isEmpty)
  }

  func testEmptyOutputIsRejected() async throws {
    let source = try makeSource()
    do {
      _ = try await pipeline(.empty).run(input: source, route: route())
      XCTFail("expected failure")
    } catch let error as ZestError {
      guard case .emptyOutput = error else { return XCTFail("wrong error \(error)") }
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["photo.png"])
  }

  func testBackendProducingNothingFails() async throws {
    let source = try makeSource()
    do {
      _ = try await pipeline(.none).run(input: source, route: route())
      XCTFail("expected failure")
    } catch let error as ZestError {
      guard case .noOutputProduced = error else { return XCTFail("wrong error \(error)") }
    }
  }

  func testMissingBackendAndMissingSource() async throws {
    let source = try makeSource()
    do {
      _ = try await pipeline(.ok).run(input: source, route: route(backend: "ghost"))
      XCTFail("expected failure")
    } catch let error as ZestError {
      guard case .backendMissing("ghost") = error else { return XCTFail("wrong error \(error)") }
    }
    do {
      _ = try await pipeline(.ok).run(input: dir.appendingPathComponent("nope.png"), route: route())
      XCTFail("expected failure")
    } catch let error as ZestError {
      guard case .sourceMissing = error else { return XCTFail("wrong error \(error)") }
    }
  }

  func testCancellationLeavesNoPartialOutput() async throws {
    let source = try makeSource()
    let pipe = pipeline(.slow)
    let r = route()
    let task = Task { try await pipe.run(input: source, route: r) }
    try await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["photo.png"])
    XCTAssertTrue(tempLeftovers().isEmpty)
  }

  func testTwoHopRunsEachStepAndPublishesFinalFormat() async throws {
    let source = try makeSource()
    let two = Route(steps: [
      Capability(
        backendID: "fake", input: [.png], output: .tiff, quality: 90, isNative: true,
        isLosslessOutput: true),
      Capability(backendID: "fake", input: [.tiff], output: .jpeg, quality: 90, isNative: true),
    ])
    let out = try await pipeline(.ok).run(input: source, route: two)
    XCTAssertEqual(out.lastPathComponent, "photo.jpg")
    XCTAssertTrue(tempLeftovers().isEmpty)
  }

  func testCustomDestinationDirectory() async throws {
    let source = try makeSource()
    let dest = dir.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let out = try await pipeline(.ok).run(input: source, route: route(), destinationDirectory: dest)
    XCTAssertEqual(out.deletingLastPathComponent().path, dest.path)
  }
}
