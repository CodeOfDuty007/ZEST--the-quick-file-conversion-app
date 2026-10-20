import UniformTypeIdentifiers
import XCTest

@testable import ZestCore

/// Writes `pages` files per run, optionally failing for inputs named "bad", and records
/// how many runs overlapped.
private final class Probe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private(set) var peak = 0
  func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
  func leave() { lock.lock(); active -= 1; lock.unlock() }
}

private struct PagesBackend: Backend {
  let id = "pages"
  let pages: Int
  let probe: Probe
  func capabilities() -> [Capability] { [] }
  func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
    probe.enter()
    defer { probe.leave() }
    try await Task.sleep(nanoseconds: 60_000_000)
    let stem = job.input.deletingPathExtension().lastPathComponent
    if stem.hasPrefix("bad") { throw NSError(domain: "fake", code: 1) }
    let ext = Formats.fileExtension(for: job.capability.output)
    return try (1...pages).map { n in
      let url = job.outputDirectory.appendingPathComponent("\(stem) page \(n).\(ext)")
      try Data("p\(n)".utf8).write(to: url)
      return url
    }
  }
}

final class BatchAndMultiOutputTests: XCTestCase {
  private var base: URL!
  private var dir: URL!
  private var temp: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("zest-batch-\(UUID().uuidString)")
    dir = base.appendingPathComponent("files")
    temp = base.appendingPathComponent("tmp")
    for url in [dir!, temp!] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

  private func source(_ name: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url
  }

  private func route(_ output: UTType = .png) -> Route {
    Route(steps: [Capability(backendID: "pages", input: [.pdf], output: output, quality: 80, isNative: true)])
  }

  private func pipeline(pages: Int, probe: Probe = Probe()) -> JobPipeline {
    JobPipeline(backends: [PagesBackend(pages: pages, probe: probe)], tempRoot: temp)
  }

  func testSeveralOutputsKeepTheirOwnNames() async throws {
    let doc = try source("report.pdf")
    let outs = try await pipeline(pages: 3).runAll(input: doc, route: route())
    XCTAssertEqual(outs.map(\.lastPathComponent), ["report page 1.png", "report page 2.png", "report page 3.png"])
    XCTAssertTrue(outs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  func testSingleOutputIsNamedAfterTheSource() async throws {
    let doc = try source("report.pdf")
    let outs = try await pipeline(pages: 1).runAll(input: doc, route: route())
    XCTAssertEqual(outs.map(\.lastPathComponent), ["report.png"])
  }

  func testSecondHopRunsOnEveryIntermediateFile() async throws {
    struct Second: Backend {
      let id = "second"
      func capabilities() -> [Capability] { [] }
      func run(_ job: JobSpec, progress: Progress) async throws -> [URL] {
        let stem = job.input.deletingPathExtension().lastPathComponent
        let url = job.outputDirectory.appendingPathComponent("\(stem).webp")
        try Data("w".utf8).write(to: url)
        return [url]
      }
    }
    let two = Route(steps: [
      Capability(backendID: "pages", input: [.pdf], output: .png, quality: 80, isNative: true),
      Capability(backendID: "second", input: [.png], output: .webP, quality: 80, isNative: true),
    ])
    let pipe = JobPipeline(backends: [PagesBackend(pages: 2, probe: Probe()), Second()], tempRoot: temp)
    let doc = try source("deck.pdf")
    let outs = try await pipe.runAll(input: doc, route: two)
    XCTAssertEqual(outs.map(\.lastPathComponent), ["deck page 1.webp", "deck page 2.webp"])
  }

  func testRunStillReturnsTheFirstOutput() async throws {
    let doc = try source("one.pdf")
    let out = try await pipeline(pages: 1).run(input: doc, route: route())
    XCTAssertEqual(out.lastPathComponent, "one.png")
  }

  func testBatchConvertsFilesAtTheSameTimeAndKeepsOrder() async throws {
    let names = (1...6).map { "doc\($0).pdf" }
    let urls = try names.map(source)
    let probe = Probe()
    let items = await pipeline(pages: 1, probe: probe).runBatch(
      inputs: urls, routes: Array(repeating: route(), count: urls.count), maxConcurrent: 3)
    XCTAssertEqual(items.map { $0.input.lastPathComponent }, names)
    XCTAssertGreaterThan(probe.peak, 1, "files must not run one by one")
    XCTAssertLessThanOrEqual(probe.peak, 3)
    for item in items { XCTAssertNoThrow(try item.result.get()) }
  }

  func testOneFailureDoesNotStopTheOthers() async throws {
    let urls = try ["a.pdf", "bad.pdf", "c.pdf"].map(source)
    let items = await pipeline(pages: 1).runBatch(
      inputs: urls, routes: Array(repeating: route(), count: 3))
    XCTAssertNoThrow(try items[0].result.get())
    XCTAssertThrowsError(try items[1].result.get())
    XCTAssertNoThrow(try items[2].result.get())
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.png").path))
  }

  func testFailedMultiOutputLeavesNothingBehind() async throws {
    let doc = try source("bad.pdf")
    _ = try? await pipeline(pages: 2).runAll(input: doc, route: route())
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    XCTAssertEqual(leftovers, ["bad.pdf"])
  }
}

final class DocumentTypesTests: XCTestCase {
  func testMarkdownAndHTMLAreRealOutputFormats() {
    XCTAssertEqual(Formats.fileExtension(for: Formats.markdown), "md")
    XCTAssertEqual(Formats.fileExtension(for: .html), "html")
    XCTAssertEqual(Formats.type(named: "md")?.conforms(to: Formats.markdown), true)
  }

  func testZipSignatureDoesNotHideOfficeDocuments() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-sniff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let header = Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0])
    let docx = dir.appendingPathComponent("memo.docx")
    let zip = dir.appendingPathComponent("bundle.zip")
    try header.write(to: docx)
    try header.write(to: zip)
    XCTAssertEqual(ContentSniffer.type(ofFileAt: docx), UTType(filenameExtension: "docx"))
    XCTAssertEqual(ContentSniffer.type(ofFileAt: zip), .zip)
  }

  func testMixedPDFAndImageSelectionStillOffersConversions() {
    let router = Router(capabilities: [
      Capability(backendID: "r", input: [.pdf], output: .jpeg, quality: 80, isNative: true),
      Capability(backendID: "r", input: [.pdf, .png], output: Formats.markdown, quality: 80, isNative: true),
      Capability(backendID: "i", input: [.png], output: .jpeg, quality: 80, isNative: true),
      Capability(backendID: "i", input: [.png, .pdf], output: .html, quality: 80, isNative: true),
    ])
    let outputs = router.resolve(inputs: [.pdf, .png]).available.map(\.output)
    XCTAssertEqual(Set(outputs), [.jpeg, Formats.markdown, .html])
  }
}
