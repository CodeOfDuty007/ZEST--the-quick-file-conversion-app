import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZestCore

@testable import ZestBackends

final class PDFRenderTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-pdfrender-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func makePDF(pages: Int, named name: String = "doc.pdf") throws -> URL {
    let url = dir.appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for _ in 0..<pages {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  private func capability(_ type: UTType) throws -> Capability {
    try XCTUnwrap(PDFRenderBackend().capabilities().first { $0.output == type })
  }

  private func size(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
  }

  private func out() throws -> URL {
    let url = dir.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testCapabilities() throws {
    let caps = PDFRenderBackend().capabilities()
    XCTAssertTrue(caps.allSatisfy { $0.input == [.pdf] && $0.isNative })
    XCTAssertEqual(caps.filter(\.isLosslessOutput).map(\.output), [.png])
    XCTAssertFalse(caps.contains { $0.output == .pdf })
  }

  func testThreePagesToPNG() async throws {
    let pdf = try makePDF(pages: 3)
    let files = try await PDFRenderBackend().run(
      JobSpec(input: pdf, capability: try capability(.png), outputDirectory: try out()),
      progress: Progress())
    XCTAssertEqual(files.map(\.lastPathComponent), ["doc page 1.png", "doc page 2.png", "doc page 3.png"])
    for file in files {
      let s = try XCTUnwrap(size(file))
      XCTAssertEqual(s.0, 417)  // 200 * 150/72
      XCTAssertEqual(s.1, 208)
    }
  }

  func testPaddingForTwelvePages() async throws {
    let pdf = try makePDF(pages: 12)
    let files = try await PDFRenderBackend().run(
      JobSpec(input: pdf, capability: try capability(.png), outputDirectory: try out()),
      progress: Progress())
    XCTAssertEqual(files.first?.lastPathComponent, "doc page 01.png")
    XCTAssertEqual(files.last?.lastPathComponent, "doc page 12.png")
  }

  func testSinglePageKeepsSourceName() async throws {
    let pdf = try makePDF(pages: 1, named: "report.pdf")
    let files = try await PDFRenderBackend().run(
      JobSpec(input: pdf, capability: try capability(.png), outputDirectory: try out()),
      progress: Progress())
    XCTAssertEqual(files.map(\.lastPathComponent), ["report.png"])
    XCTAssertNotNil(size(files[0]))
  }

  func testJPEGDecodes() async throws {
    let pdf = try makePDF(pages: 2)
    let files = try await PDFRenderBackend().run(
      JobSpec(
        input: pdf, capability: try capability(.jpeg), outputDirectory: try out(),
        params: ["quality": "70"]),
      progress: Progress())
    XCTAssertEqual(files.map(\.pathExtension), ["jpg", "jpg"])
    XCTAssertNotNil(size(files[0]))
  }

  func testUnreadablePDFThrows() async throws {
    let bad = dir.appendingPathComponent("bad.pdf")
    try Data("not a pdf".utf8).write(to: bad)
    do {
      _ = try await PDFRenderBackend().run(
        JobSpec(input: bad, capability: try capability(.png), outputDirectory: try out()),
        progress: Progress())
      XCTFail("expected throw")
    } catch BackendError.unreadable {
    }
  }

  func testPipelinePublishesAllPagesBesideSource() async throws {
    let pdf = try makePDF(pages: 3, named: "scan.pdf")
    let route = Route(steps: [try capability(.png)])
    let pipeline = JobPipeline(backends: [PDFRenderBackend(), ImageIOBackend()])
    let published = try await pipeline.runAll(input: pdf, route: route)
    XCTAssertEqual(
      published.map(\.lastPathComponent).sorted(),
      ["scan page 1.png", "scan page 2.png", "scan page 3.png"])
    for file in published {
      XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }
  }
}
