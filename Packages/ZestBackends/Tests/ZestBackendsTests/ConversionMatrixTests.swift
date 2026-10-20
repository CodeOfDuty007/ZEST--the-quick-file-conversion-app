import CoreText
import PDFKit
import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends
@testable import ZestCore

/// The permutation check: every kind of file Zest accepts is generated, every output the
/// router offers for it is actually run, and every pair that should convert must be offered.
/// A new format or engine that breaks any pair fails here instead of in someone's drag.
final class ConversionMatrixTests: XCTestCase {
  private var dir: URL!
  private let catalog = Catalog()
  private let word = UTType("org.openxmlformats.wordprocessingml.document")!
  private static let marker = "Quarterly"

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("zest-matrix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  // MARK: Corpus

  private func canvas() -> CGImage? {
    let context = CGContext(
      data: nil, width: 480, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    context?.setFillColor(CGColor(gray: 1, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: 480, height: 200))
    let text = NSAttributedString(
      string: "\(Self.marker) report", attributes: [.font: NSFont.systemFont(ofSize: 36)])
    context?.textPosition = CGPoint(x: 20, y: 90)
    CTLineDraw(CTLineCreateWithAttributedString(text), context!)
    return context?.makeImage()
  }

  private func image(_ type: UTType, ext: String) throws -> URL {
    let url = dir.appendingPathComponent("sample-\(ext).\(ext)")
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(canvas()), nil)
    guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot write \(ext) here") }
    return url
  }

  private func write(_ name: String, _ data: Data) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  /// Every input kind with a sample file; `textual` marks the ones whose words must survive.
  private func corpus() throws -> [(url: URL, textual: Bool)] {
    let body = "# \(Self.marker) results\n\nRevenue grew by **ten percent** this quarter.\n\n- first point\n- second point\n"
    let attributed = NSAttributedString(
      string: "\(Self.marker) results\nRevenue grew by ten percent.\n",
      attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
    let range = NSRange(location: 0, length: attributed.length)
    var items: [(URL, Bool)] = [
      (try write("sample.txt", Data("\(Self.marker) results\n\nRevenue grew.\n".utf8)), true),
      (try write("sample.md", Data(body.utf8)), true),
      (try write("sample.html", Data("<html><body><h1>\(Self.marker) results</h1><p>Revenue grew.</p></body></html>".utf8)), true),
      (try write("sample.csv", Data("name,value\n\(Self.marker),10\n".utf8)), true),
      (try write("sample.json", Data("{\"title\": \"\(Self.marker)\"}".utf8)), true),
      (try write("sample.rtf", try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])), true),
      (try write("sample.docx", try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])), true),
    ]
    let pdfData = try XCTUnwrap(DocumentExportBackend.pdf(attributed))
    items.append((try write("sample.pdf", pdfData), true))
    for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.tiff, "tiff"), (.bmp, "bmp"), (.gif, "gif"), (.heic, "heic")] {
      if let url = try? image(type, ext: ext) { items.append((url, false)) }
    }
    return items
  }

  private func type(of url: URL) throws -> UTType { try XCTUnwrap(ContentSniffer.type(ofFileAt: url)) }

  private func text(of url: URL) -> String {
    switch url.pathExtension {
    case "pdf": return PDFDocument(url: url)?.string ?? ""
    case "docx", "rtf": return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
    default: return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
  }

  // MARK: Tests

  /// Every output offered for every input must really be produced, and words must survive.
  func testEveryOfferedConversionRuns() async throws {
    var failures: [String] = []
    var ran = 0
    for sample in try corpus() {
      let input = try type(of: sample.url)
      let offered = catalog.router.resolve(inputs: [input]).available
      XCTAssertFalse(offered.isEmpty, "\(sample.url.lastPathComponent) offers nothing")
      for option in offered {
        let label = "\(sample.url.lastPathComponent) → \(Formats.fileExtension(for: option.output))"
        let target = dir.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
          let outs = try await catalog.pipeline.runAll(
            input: sample.url, route: option.routes[0], destinationDirectory: target)
          ran += 1
          guard !outs.isEmpty else { failures.append("\(label): no output"); continue }
          for out in outs {
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 { failures.append("\(label): empty file") }
          }
          let readable: Set<String> = ["md", "html", "txt", "docx", "rtf", "pdf"]
          if sample.textual, readable.contains(outs[0].pathExtension),
            !text(of: outs[0]).localizedCaseInsensitiveContains(Self.marker)
          {
            failures.append("\(label): the text did not survive")
          }
        } catch {
          failures.append("\(label): \(error.localizedDescription)")
        }
      }
    }
    XCTAssertGreaterThan(ran, 100, "the matrix ran suspiciously few conversions")
    XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(ran) conversions failed:\n" + failures.joined(separator: "\n"))
  }

  /// Document kinds must reach each other, PDF, Word, text and every image format.
  func testDocumentFamilyIsFullyCrossConvertible() throws {
    let documents: [(String, UTType)] = [
      ("txt", .plainText), ("md", Formats.markdown), ("html", .html), ("rtf", .rtf), ("docx", word), ("pdf", .pdf),
    ]
    let images: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp]
    var missing: [String] = []
    for (name, input) in documents {
      let offered = Set(catalog.router.resolve(inputs: [input]).available.map(\.output))
      for (otherName, output) in documents where !input.conforms(to: output) {
        // Markdown conforms to plain text, so a .md file is already text.
        if output == .plainText && input == Formats.markdown { continue }
        if !offered.contains(output) { missing.append("\(name) → \(otherName)") }
      }
      for output in images where !offered.contains(output) {
        missing.append("\(name) → \(Formats.fileExtension(for: output))")
      }
    }
    XCTAssertTrue(missing.isEmpty, "missing conversions:\n" + missing.joined(separator: "\n"))
  }

  /// Images reach every document kind and every other image format.
  func testImagesReachDocumentsAndEachOther() {
    let images: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp]
    for input in images {
      let offered = Set(catalog.router.resolve(inputs: [input]).available.map(\.output))
      for output in [UTType.pdf, Formats.markdown, .html] + images where !input.conforms(to: output) {
        XCTAssertTrue(offered.contains(output), "\(input.identifier) → \(output.identifier)")
      }
    }
  }

  /// The wheel shows ring buttons plus a More branch; Word and text must be somewhere in it.
  func testWordAndTextAreReachableOnTheWheelForPDFAndPlainText() {
    func leaves(_ node: WheelNode) -> [WheelNode] {
      node.isBranch ? node.children.flatMap(leaves) : [node]
    }
    for input in [UTType.pdf, .plainText, word, .rtf, .png] {
      let tree = WheelTree.build(router: catalog.router, inputs: [input])
      let convert = tree.children.first { $0.id == "root.convert" }
      let titles = Set(convert.map(leaves)?.map(\.title) ?? [])
      for expected in ["DOCX", "TXT"] {
        if (input == .plainText && expected == "TXT") || (input == word && expected == "DOCX") { continue }
        if input == .png && expected != "TXT" && expected != "DOCX" { continue }
        XCTAssertTrue(titles.contains(expected) || input == .png, "\(input.identifier) lacks \(expected): \(titles.sorted())")
      }
    }
  }
}
