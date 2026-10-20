import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends
@testable import ZestCore

/// End to end through the real catalog: what the wheel offers for a PDF and what it produces.
final class CrossConversionTests: XCTestCase {
  private var dir: URL!
  private let catalog = Catalog()

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-cross-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func makePDF(pages: Int) throws -> URL {
    let url = dir.appendingPathComponent("report.pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    for n in 1...pages {
      context.beginPDFPage(nil)
      let text = NSAttributedString(
        string: "Quarterly figures page \(n)", attributes: [.font: NSFont.systemFont(ofSize: 14)])
      let line = CTLineCreateWithAttributedString(text)
      context.textPosition = CGPoint(x: 20, y: 100)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  func testPDFOffersEveryImageFormatMarkdownAndHTML() {
    let outputs = Set(catalog.router.resolve(inputs: [.pdf]).available.map(\.output))
    for expected in [UTType.jpeg, .png, .heic, .tiff, .gif, .bmp, Formats.markdown, .html] {
      XCTAssertTrue(outputs.contains(expected), "missing \(expected.identifier)")
    }
    XCTAssertFalse(outputs.contains(.pdf))
  }

  func testPDFAndImageTogetherStillConvert() {
    let outputs = Set(catalog.router.resolve(inputs: [.pdf, .png]).available.map(\.output))
    XCTAssertTrue(outputs.isSuperset(of: [.jpeg, Formats.markdown, .html]))
  }

  func testEveryKindOfFileOffersMarkdownAndHTML() {
    var types: [UTType] = [.pdf, .png, .jpeg, .plainText, .rtf, .mpeg4Movie, .mp3, .wav, .json, .commaSeparatedText]
    types += ["docx", "odt"].compactMap { UTType(filenameExtension: $0) }
    for type in types {
      let outputs = Set(catalog.router.resolve(inputs: [type]).available.map(\.output))
      let expected: [UTType] = [Formats.markdown, .html].filter { !type.conforms(to: $0) }
      for output in expected { XCTAssertTrue(outputs.contains(output), "\(type.identifier) → \(output.identifier)") }
    }
  }

  func testMultiPagePDFBecomesOneImagePerPage() async throws {
    let pdf = try makePDF(pages: 3)
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .pdf, to: .png))
    let outs = try await catalog.pipeline.runAll(input: pdf, route: route)
    XCTAssertEqual(outs.count, 3)
  }

  func testPDFToMarkdownAndHTMLCarryTheText() async throws {
    let pdf = try makePDF(pages: 1)
    for output in [Formats.markdown, UTType.html] {
      let route = try XCTUnwrap(catalog.router.bestRoute(from: .pdf, to: output))
      XCTAssertEqual(route.hops, 1)
      let out = try await catalog.pipeline.run(input: pdf, route: route)
      let text = try String(contentsOf: out, encoding: .utf8)
      XCTAssertTrue(text.contains("Quarterly figures"), text)
    }
  }

  func testMarkdownConvertsToHTMLAndBack() async throws {
    let md = dir.appendingPathComponent("note.md")
    try Data("# Title\n\nSome **bold** text.\n".utf8).write(to: md)
    let toHTML = try XCTUnwrap(catalog.router.bestRoute(from: Formats.markdown, to: .html))
    let html = try await catalog.pipeline.run(input: md, route: toHTML)
    let page = try String(contentsOf: html, encoding: .utf8)
    XCTAssertTrue(page.contains("<h1>Title</h1>") && page.contains("<strong>bold</strong>"))
    let back = try XCTUnwrap(catalog.router.bestRoute(from: .html, to: Formats.markdown))
    let out = try await catalog.pipeline.run(input: html, route: back)
    let text = try String(contentsOf: out, encoding: .utf8)
    XCTAssertTrue(text.contains("Title") && text.contains("**bold**"), text)
  }

  func testAutoRedactAppliesToPDFTextAndImages() {
    let tool = catalog.router.tools.first { $0.id == "redact.auto" }
    XCTAssertNotNil(tool)
    for type in [UTType.pdf, .plainText, .png, .jpeg] {
      XCTAssertEqual(catalog.router.visibility(of: tool!, inputs: [type]), .enabled, type.identifier)
    }
  }
}
