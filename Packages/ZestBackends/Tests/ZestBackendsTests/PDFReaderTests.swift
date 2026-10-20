import AppKit
import XCTest

@testable import ZestBackends

final class PDFReaderTests: XCTestCase {
  private func makePDF(pages: [[(String, CGFloat, Bool, CGFloat, CGFloat)]]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pdfreader-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
    for page in pages {
      context.beginPDFPage(nil)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      for (text, size, bold, x, y) in page {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
          .draw(at: CGPoint(x: x, y: y))
      }
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  func testStructure() async throws {
    let url = try makePDF(pages: [
      [
        ("Quarterly Report", 28, true, 72, 700),
        ("This is the first paragraph of the document and it runs on", 12, false, 72, 650),
        ("to a second line that continues the same thought.", 12, false, 72, 636),
        ("A separate second paragraph begins here after a gap and", 12, false, 72, 600),
        ("finishes on this line.", 12, false, 72, 586),
        ("\u{2022} First bullet item", 12, false, 72, 540),
        ("\u{2022} Second bullet item", 12, false, 72, 524),
      ],
      [("Page two body text lives here.", 12, false, 72, 700)],
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let doc = try await PDFReader.read(url: url)
    func text(_ inlines: [Inline]) -> String { inlines.map(\.text).joined() }

    XCTAssertEqual(doc.title, "Quarterly Report")
    guard case .heading(let level, let h) = doc.blocks[0] else { return XCTFail("\(doc.blocks)") }
    XCTAssertEqual(level, 1)
    XCTAssertEqual(text(h), "Quarterly Report")

    guard case .paragraph(let p1) = doc.blocks[1], case .paragraph(let p2) = doc.blocks[2] else {
      return XCTFail("\(doc.blocks)")
    }
    XCTAssertTrue(text(p1).hasPrefix("This is the first paragraph"))
    XCTAssertTrue(text(p1).hasSuffix("continues the same thought."))
    XCTAssertTrue(text(p1).contains("runs on to a second line"))
    XCTAssertTrue(text(p2).hasPrefix("A separate second paragraph"))
    XCTAssertTrue(text(p2).hasSuffix("finishes on this line."))

    guard case .listItem(false, _, let i1) = doc.blocks[3],
      case .listItem(false, _, let i2) = doc.blocks[4]
    else { return XCTFail("\(doc.blocks)") }
    XCTAssertEqual(text(i1), "First bullet item")
    XCTAssertEqual(text(i2), "Second bullet item")

    XCTAssertEqual(doc.blocks[5], .rule)
    guard case .paragraph(let last) = doc.blocks[6] else { return XCTFail("\(doc.blocks)") }
    XCTAssertEqual(text(last), "Page two body text lives here.")
    XCTAssertEqual(doc.blocks.count, 7)
  }

  func testUnreadableThrows() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).pdf")
    do {
      _ = try await PDFReader.read(url: url)
      XCTFail("expected throw")
    } catch {}
  }
}
