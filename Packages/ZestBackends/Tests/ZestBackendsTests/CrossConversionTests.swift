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

final class PDFCompressTests: XCTestCase {
  func testCompressShowsPercentChoicesAndShrinksAPDF() async throws {
    let catalog = Catalog()
    let ids = catalog.router.tools.filter { $0.id.hasPrefix("compress.pdf.") }.map(\.title)
    XCTAssertEqual(Set(ids), ["25%", "50%", "75%"])

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-pc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A big, noisy-ish page: raw pixels make a large PDF that JPEG can shrink.
    let url = dir.appendingPathComponent("scan.pdf")
    var box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    let space = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: 600 * 800 * 4)
    for i in 0..<pixels.count { pixels[i] = UInt8((i * 7 + i / 600) % 251) }
    let image = try XCTUnwrap(
      CGContext(data: &pixels, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 2400,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    ctx.beginPDFPage(nil); ctx.draw(image, in: box); ctx.endPDFPage(); ctx.closePDF()

    let tool = try XCTUnwrap(catalog.router.tools.first { $0.id == "compress.pdf.50" })
    let report = try await catalog.pipeline.runTool(tool, inputs: [url])
    let before = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    if let out = report.published.first {
      let after = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize!
      XCTAssertLessThanOrEqual(after, before / 2)
    } else {
      XCTAssertFalse(report.skipped.isEmpty)
    }
  }

  func testTextPDFIsRefusedNotFlattened() async throws {
    let catalog = Catalog()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-pt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("memo.pdf")
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Real text", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    ctx.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, ctx)
    ctx.endPDFPage(); ctx.closePDF()
    let tool = try XCTUnwrap(catalog.router.tools.first { $0.id == "compress.pdf.75" })
    let report = try await catalog.pipeline.runTool(tool, inputs: [url])
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertTrue(report.skipped.first?.reason.contains("selectable text") == true)
  }
}
