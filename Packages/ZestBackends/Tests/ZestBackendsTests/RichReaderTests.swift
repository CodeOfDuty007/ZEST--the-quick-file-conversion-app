import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends

final class RichReaderTests: XCTestCase {
  var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-rich-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func text(_ inlines: [Inline]) -> String { inlines.map(\.text).joined() }

  func testHTML() async throws {
    let html = """
      <html><head><title>x</title><script>alert(1)</script></head><body>
      <h1>Main Title</h1>
      <p>This is a body paragraph with <strong>bold</strong>, <em>italic</em> and a
      <a href="https://example.com/">link</a>, plus plenty of extra words so the body text dominates.</p>
      <h2>Section</h2>
      <p>Another paragraph of ordinary text that keeps the body size dominant in this document.</p>
      <ul><li>apple</li><li>banana</li></ul>
      <ol><li>first</li><li>second</li></ol>
      <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Pear</td><td>3</td></tr></table>
      </body></html>
      """
    let url = dir.appendingPathComponent("page.html")
    try html.write(to: url, atomically: true, encoding: .utf8)
    let doc = try await RichReader.read(url: url, type: .html)

    XCTAssertEqual(doc.title, "Main Title")
    XCTAssertTrue(doc.blocks.contains { if case .heading(1, let i) = $0 { return text(i) == "Main Title" } else { return false } })
    XCTAssertTrue(doc.blocks.contains { if case .heading(2, let i) = $0 { return text(i) == "Section" } else { return false } })

    let paragraph = doc.blocks.compactMap { b -> [Inline]? in
      if case .paragraph(let i) = b, text(i).hasPrefix("This is a body") { return i } else { return nil }
    }.first
    let runs = try XCTUnwrap(paragraph)
    XCTAssertTrue(runs.contains { $0.bold && $0.text == "bold" })
    XCTAssertTrue(runs.contains { $0.italic && $0.text == "italic" })
    XCTAssertTrue(runs.contains { $0.link == "https://example.com/" && $0.text == "link" })

    let items = doc.blocks.compactMap { b -> (Bool, String)? in
      if case .listItem(let o, _, let i) = b { return (o, text(i)) } else { return nil }
    }
    XCTAssertEqual(items.map(\.1), ["apple", "banana", "first", "second"])
    XCTAssertEqual(items.map(\.0), [false, false, true, true])

    let table = doc.blocks.compactMap { b -> ([[Inline]], [[[Inline]]])? in
      if case .table(let h, let r) = b { return (h, r) } else { return nil }
    }.first
    let (header, rows) = try XCTUnwrap(table)
    XCTAssertEqual(header.map(text), ["Name", "Qty"])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].map(text), ["Pear", "3"])
    XCTAssertFalse(doc.blocks.contains { if case .paragraph(let i) = $0 { return text(i).contains("alert") } else { return false } })
  }

  func testRTF() async throws {
    let attributed = NSMutableAttributedString()
    attributed.append(
      NSAttributedString(
        string: "Big Heading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 28)]))
    let body = NSFont.systemFont(ofSize: 12)
    attributed.append(NSAttributedString(string: "Plain text with ", attributes: [.font: body]))
    attributed.append(
      NSAttributedString(
        string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
    attributed.append(
      NSAttributedString(
        string: " and a long tail of ordinary words to dominate the size count.\n", attributes: [.font: body]))
    attributed.append(NSAttributedString(string: "• bullet one\n", attributes: [.font: body]))
    attributed.append(NSAttributedString(string: "1. numbered one\n", attributes: [.font: body]))
    let data = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let url = dir.appendingPathComponent("note.rtf")
    try data.write(to: url)

    let doc = try await RichReader.read(url: url, type: .rtf)
    XCTAssertEqual(doc.title, "Big Heading")
    XCTAssertEqual(doc.blocks.first, .heading(1, [Inline("Big Heading")]))
    guard case .paragraph(let runs)? = doc.blocks.dropFirst().first else { return XCTFail("\(doc.blocks)") }
    XCTAssertTrue(runs.contains { $0.bold && $0.text == "bold" })
    XCTAssertTrue(doc.blocks.contains(.listItem(ordered: false, depth: 0, [Inline("bullet one")])))
    XCTAssertTrue(doc.blocks.contains(.listItem(ordered: true, depth: 0, [Inline("numbered one")])))
  }

  func testDOCX() async throws {
    let attributed = NSMutableAttributedString(
      string: "Report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 26)])
    attributed.append(
      NSAttributedString(
        string: "Some body text goes here and it is long enough to be the dominant size.\n",
        attributes: [.font: NSFont.systemFont(ofSize: 12)]))
    let data = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    let url = dir.appendingPathComponent("report.docx")
    try data.write(to: url)

    let type = try XCTUnwrap(UTType(filenameExtension: "docx"))
    let doc = try await RichReader.read(url: url, type: type)
    XCTAssertEqual(doc.title, "Report")
    XCTAssertTrue(doc.blocks.contains { if case .paragraph(let i) = $0 { return text(i).hasPrefix("Some body text") } else { return false } })
  }

  func testUnreadableThrows() async {
    let url = dir.appendingPathComponent("missing.docx")
    let type = UTType(filenameExtension: "docx") ?? .data
    do {
      _ = try await RichReader.read(url: url, type: type)
      XCTFail("expected throw")
    } catch {
      guard case BackendError.unreadable = error else { return XCTFail("\(error)") }
    }
  }
}
