import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import XCTest
import ZestCore

@testable import ZestBackends

final class RedactTests: XCTestCase {
  var dir: URL!
  let backend = RedactBackend()

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-redact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func matches(_ text: String) -> [String] {
    SensitiveText.ranges(in: text).map { String(text[$0]) }
  }

  private func run(_ url: URL) async throws -> JobPipeline.ToolReport {
    let pipeline = JobPipeline(backends: [backend])
    return try await pipeline.runTool(backend.tools()[0], inputs: [url], destinationDirectory: dir)
  }

  // MARK: Detection

  func testPositives() {
    XCTAssertEqual(matches("mail john.doe+x@example.co.uk now"), ["john.doe+x@example.co.uk"])
    XCTAssertEqual(matches("SSN 123-45-6789."), ["123-45-6789"])
    XCTAssertEqual(matches("card 4111 1111 1111 1111 ok"), ["4111 1111 1111 1111"])
    XCTAssertEqual(matches("card 4111-1111-1111-1111"), ["4111-1111-1111-1111"])
    XCTAssertEqual(matches("host 192.168.1.20 up"), ["192.168.1.20"])
    XCTAssertEqual(matches("iban GB82 WEST 1234 5698 7654 32 end"), ["GB82 WEST 1234 5698 7654 32"])
    XCTAssertEqual(matches("call (415) 555-2671 today"), ["(415) 555-2671"])
    XCTAssertEqual(matches("call +44 20 7946 0958"), ["+44 20 7946 0958"])
    XCTAssertEqual(matches("call 415-555-2671"), ["415-555-2671"])
    XCTAssertEqual(matches("call 4155552671"), ["4155552671"])
  }

  func testNegatives() {
    XCTAssertEqual(matches("Meeting on 2024-01-15 at 10:30"), [])
    XCTAssertEqual(matches("Date 12-31-2024"), [])
    XCTAssertEqual(matches("order 12345 and 987654"), [])
    XCTAssertEqual(matches("pi is 3.14159265"), [])
    XCTAssertEqual(matches("not a card 4111 1111 1111 1112"), [])
    XCTAssertEqual(matches("digits 1234567890123456"), [])
    XCTAssertEqual(matches("version 1.2.3 and 300.1.1.1"), [])
    XCTAssertEqual(matches("at sign @ alone, user@ host"), [])
  }

  func testMergedNonOverlapping() {
    let text = "a@b.com, 4111 1111 1111 1111, 10.0.0.1"
    let ranges = SensitiveText.ranges(in: text)
    XCTAssertEqual(ranges.count, 3)
    for pair in zip(ranges, ranges.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.upperBound, pair.1.lowerBound) }
  }

  // MARK: Tool

  func testToolSpec() {
    let tool = backend.tools()[0]
    XCTAssertEqual(tool.id, "redact.auto")
    XCTAssertEqual(tool.root, .edit)
    XCTAssertEqual(tool.nameSuffix, " redacted")
  }

  func testTextFile() async throws {
    let url = dir.appendingPathComponent("notes.txt")
    try "Reach me at jane@corp.com or +1 (415) 555-2671. Card 4111 1111 1111 1111. Keep this."
      .write(to: url, atomically: true, encoding: .utf8)
    let report = try await run(url)
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.lastPathComponent, "notes redacted.txt")
    let text = try String(contentsOf: out, encoding: .utf8)
    XCTAssertFalse(text.contains("jane@corp.com"))
    XCTAssertFalse(text.contains("555-2671"))
    XCTAssertFalse(text.contains("4111"))
    XCTAssertTrue(text.contains("[REDACTED]"))
    XCTAssertTrue(text.contains("Keep this."))
  }

  func testRTF() async throws {
    let url = dir.appendingPathComponent("letter.rtf")
    let attributed = NSAttributedString(string: "Write to bob@example.org about it.")
    try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ).write(to: url)
    let report = try await run(url)
    let out = try XCTUnwrap(report.published.first)
    let result = try NSAttributedString(
      url: out, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    XCTAssertFalse(result.string.contains("bob@example.org"))
    XCTAssertTrue(result.string.contains("[REDACTED]"))
    XCTAssertTrue(result.string.contains("about it."))
  }

  func testNothingFoundSkips() async throws {
    let url = dir.appendingPathComponent("plain.txt")
    try "Nothing to see on 2024-01-15.".write(to: url, atomically: true, encoding: .utf8)
    let report = try await run(url)
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertEqual(report.skipped.first?.reason, "Nothing sensitive found")
  }

  private func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
  }

  private func recognized(_ image: CGImage) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  }

  func testPNG() async throws {
    let width = 900, height = 200
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    draw("Contact: john@example.com", in: context, at: CGPoint(x: 30, y: 80), size: 64)
    let url = dir.appendingPathComponent("shot.png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let before = try recognized(OrientedImage.load(url)!)
    try XCTSkipIf(
      before.allSatisfy { SensitiveText.ranges(in: $0).isEmpty }, "Vision found no email headless")

    let report = try await run(url)
    let out = try XCTUnwrap(report.published.first)
    XCTAssertNotEqual(try Data(contentsOf: out), try Data(contentsOf: url))
    let after = try recognized(OrientedImage.load(out)!)
    XCTAssertTrue(after.allSatisfy { SensitiveText.ranges(in: $0).isEmpty }, "\(after)")
    XCTAssertFalse(after.joined().contains("john@example"))
  }

  func testPDF() async throws {
    let url = dir.appendingPathComponent("doc.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
    for (text, _) in [("Contact john@example.com please", 0), ("Quarterly summary stays readable", 1)] {
      pdf.beginPDFPage(nil)
      pdf.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      draw(text, in: pdf, at: CGPoint(x: 72, y: 600), size: 24)
      pdf.endPDFPage()
    }
    pdf.closePDF()
    XCTAssertTrue(PDFDocument(url: url)?.string?.contains("john@example.com") == true)

    let report = try await run(url)
    let out = try XCTUnwrap(report.published.first)
    let result = try XCTUnwrap(PDFDocument(url: out))
    XCTAssertEqual(result.pageCount, 2)
    let text = result.string ?? ""
    XCTAssertFalse(text.contains("john@example.com"))
    XCTAssertFalse(text.contains("example.com"))
    XCTAssertTrue(text.contains("Quarterly summary"))
    XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).size, box.size)
  }

  func testPDFNothingFound() async throws {
    let url = dir.appendingPathComponent("clean.pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    draw("Hello world", in: pdf, at: CGPoint(x: 72, y: 600), size: 24)
    pdf.endPDFPage()
    pdf.closePDF()
    let report = try await run(url)
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertEqual(report.skipped.count, 1)
  }
}
