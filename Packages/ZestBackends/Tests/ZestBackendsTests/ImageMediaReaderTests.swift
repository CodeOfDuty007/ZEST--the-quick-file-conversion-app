import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends

final class ImageMediaReaderTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("imr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: dir) }

  private func textImage(_ text: String, width: Int = 1200, height: Int = 400) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 120, nil)
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
      ])
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2 - 40)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    return context.makeImage()!
  }

  private func plainText(_ blocks: [Block]) -> String {
    blocks.compactMap { block -> String? in
      switch block {
      case .heading(_, let i), .paragraph(let i): return i.map(\.text).joined()
      default: return nil
      }
    }.joined(separator: "\n")
  }

  func testOCRFindsRenderedText() throws {
    let blocks = ImageReader.ocrBlocks(for: textImage("Invoice 2024"))
    if blocks.isEmpty { throw XCTSkip("Vision returned no text in this environment") }
    XCTAssertTrue(plainText(blocks).contains("Invoice"), plainText(blocks))
  }

  func testReadEmbedsJPEGDataURI() throws {
    let url = dir.appendingPathComponent("scan.png")
    XCTAssertTrue(OrientedImage.writePNG(textImage("Invoice 2024", width: 2400, height: 800), to: url))
    let embedded = try ImageReader.read(url: url, embed: true)
    XCTAssertEqual(embedded.title, "scan")
    guard case .image(let alt, let src, let uri)? = embedded.blocks.first else {
      return XCTFail("first block must be the image")
    }
    XCTAssertEqual(alt, "scan.png")
    XCTAssertEqual(src, "scan.png")
    XCTAssertTrue(uri?.hasPrefix("data:image/jpeg;base64,") == true)

    let linked = try ImageReader.read(url: url, embed: false)
    guard case .image(_, _, let none)? = linked.blocks.first else { return XCTFail() }
    XCTAssertNil(none)
  }

  func testNoTextFallback() throws {
    let url = dir.appendingPathComponent("blank.png")
    XCTAssertTrue(OrientedImage.writePNG(textImage("", width: 200, height: 200), to: url))
    let doc = try ImageReader.read(url: url, embed: false)
    XCTAssertTrue(plainText(doc.blocks).contains("No text was found in this image."))
  }

  func testUnreadableImageThrows() {
    let url = dir.appendingPathComponent("missing.png")
    XCTAssertThrowsError(try ImageReader.read(url: url, embed: false))
  }

  func testWAVMetadata() async throws {
    let url = dir.appendingPathComponent("tone.wav")
    let rate = 8000, seconds = 2
    var pcm = Data()
    for i in 0..<(rate * seconds) {
      let sample = Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000)
      pcm.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
    }
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    var wav = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16)
    wav += le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
    wav += Data("data".utf8) + le32(pcm.count) + pcm
    try wav.write(to: url)

    let doc = try await MediaReader.read(url: url, type: .wav)
    guard case .heading(_, let h) = doc.blocks[0] else { return XCTFail() }
    XCTAssertEqual(h.map(\.text).joined(), "tone.wav")
    guard case .media(let video, let name, _) = doc.blocks[1] else { return XCTFail() }
    XCTAssertFalse(video)
    XCTAssertEqual(name, "tone.wav")
    guard case .table(_, let rows) = doc.blocks[2] else { return XCTFail() }
    let dict = Dictionary(
      uniqueKeysWithValues: rows.map { ($0[0].map(\.text).joined(), $0[1].map(\.text).joined()) })
    XCTAssertEqual(dict["Duration"], "2.0 s")
    XCTAssertEqual(dict["Sample rate"], "8000 Hz")
    XCTAssertEqual(dict["Channels"], "1")
    XCTAssertNotNil(dict["File size"])
    guard case .paragraph(let note) = doc.blocks.last! else { return XCTFail() }
    XCTAssertTrue(note.map(\.text).joined().contains("not a transcript"))
  }

  func testNonMediaThrows() async throws {
    let url = dir.appendingPathComponent("junk.wav")
    try Data("not audio".utf8).write(to: url)
    do {
      _ = try await MediaReader.read(url: url, type: .wav)
      XCTFail("expected throw")
    } catch {}
  }
}
