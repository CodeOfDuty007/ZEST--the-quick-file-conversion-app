import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends
@testable import ZestCore

final class DocumentExportTests: XCTestCase {
  private var dir: URL!
  private let catalog = Catalog()
  private let docx = UTType("org.openxmlformats.wordprocessingml.document")!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func convert(_ input: URL, to output: UTType) async throws -> [URL] {
    let type = try XCTUnwrap(ContentSniffer.type(ofFileAt: input))
    let route = try XCTUnwrap(catalog.router.bestRoute(from: type, to: output), "no route to \(output.identifier)")
    return try await catalog.pipeline.runAll(input: input, route: route)
  }

  func testTextAndWordOfferEveryDocumentAndImageFormat() {
    for type in [UTType.plainText, docx] {
      let outputs = Set(catalog.router.resolve(inputs: [type]).available.map(\.output))
      for expected in [UTType.pdf, .rtf, Formats.markdown, .html, .jpeg, .png, .heic, .tiff, .gif, .bmp] {
        if type.conforms(to: expected) { continue }
        XCTAssertTrue(outputs.contains(expected), "\(type.identifier) → \(expected.identifier)")
      }
    }
    XCTAssertTrue(Set(catalog.router.resolve(inputs: [.plainText]).available.map(\.output)).contains(docx))
  }

  func testTextBecomesWordPDFAndImage() async throws {
    let txt = dir.appendingPathComponent("letter.txt")
    try Data("Dear reader,\n\nThis is the body.\n".utf8).write(to: txt)

    let word = try await convert(txt, to: docx)
    XCTAssertEqual(word.first?.pathExtension, "docx")
    // Read the Word file back: the words must survive.
    let readBack = try NSAttributedString(url: word[0], options: [:], documentAttributes: nil)
    XCTAssertTrue(readBack.string.contains("This is the body."))

    let pdf = try await convert(txt, to: .pdf)
    XCTAssertTrue(PDFDocument(url: pdf[0])?.string?.contains("Dear reader") == true)

    let png = try await convert(txt, to: .png)
    XCTAssertEqual(png.first?.pathExtension, "png")
  }

  func testWordConvertsToTextAndRTF() async throws {
    let src = dir.appendingPathComponent("memo.txt")
    try Data("Quarterly memo\n".utf8).write(to: src)
    let word = try await convert(src, to: docx)[0]
    let txt = try await convert(word, to: .plainText)
    XCTAssertTrue(try String(contentsOf: txt[0], encoding: .utf8).contains("Quarterly memo"))
    let rtf = try await convert(word, to: .rtf)
    XCTAssertEqual(rtf[0].pathExtension, "rtf")
  }

  func testPDFConvertsToWordToo() async throws {
    let txt = dir.appendingPathComponent("a.txt")
    try Data("Findings in the PDF".utf8).write(to: txt)
    let pdf = try await convert(txt, to: .pdf)[0]
    let word = try await convert(pdf, to: docx)
    let readBack = try NSAttributedString(url: word[0], options: [:], documentAttributes: nil)
    XCTAssertTrue(readBack.string.contains("Findings"))
  }
}
