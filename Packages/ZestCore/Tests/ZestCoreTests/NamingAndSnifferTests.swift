import UniformTypeIdentifiers
import XCTest

@testable import ZestCore

final class NamingAndSnifferTests: XCTestCase {
  private let dir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)

  func testFirstCandidateIsPlainName() {
    let url = OutputNaming.uniqueURL(directory: dir, baseName: "photo", ext: "jpg") { _ in false }
    XCTAssertEqual(url.lastPathComponent, "photo.jpg")
  }

  func testCollisionsCountUpFinderStyle() {
    let taken: Set<String> = ["photo.jpg", "photo 2.jpg"]
    let url = OutputNaming.uniqueURL(directory: dir, baseName: "photo", ext: "jpg") {
      taken.contains($0.lastPathComponent)
    }
    XCTAssertEqual(url.lastPathComponent, "photo 3.jpg")
  }

  func testFormatNames() {
    XCTAssertEqual(Formats.type(named: "JPG"), .jpeg)
    XCTAssertEqual(Formats.type(named: ".png"), .png)
    XCTAssertNil(Formats.type(named: ""))
    XCTAssertEqual(Formats.fileExtension(for: .jpeg), "jpg")
    XCTAssertEqual(Formats.fileExtension(for: .mpeg4Movie), "mp4")
    XCTAssertEqual(Formats.fileExtension(for: Formats.webm), "webm")
  }

  func testSniffsMagicBytes() {
    XCTAssertEqual(ContentSniffer.type(ofHeader: Data([0x89, 0x50, 0x4E, 0x47, 0, 0])), .png)
    XCTAssertEqual(ContentSniffer.type(ofHeader: Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
    XCTAssertEqual(ContentSniffer.type(ofHeader: Data("%PDF-1.7".utf8)), .pdf)
    XCTAssertEqual(
      ContentSniffer.type(ofHeader: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webP)
    XCTAssertEqual(
      ContentSniffer.type(ofHeader: Data("\0\0\0\u{18}ftypheic".utf8)), .heic)
    XCTAssertEqual(
      ContentSniffer.type(ofHeader: Data("\0\0\0\u{18}ftypM4A ".utf8)), .mpeg4Audio)
    XCTAssertNil(ContentSniffer.type(ofHeader: Data("hello".utf8)))
  }

  func testWebMIsNotMistakenForMatroska() {
    let ebml: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82]
    let webm = Data(ebml + [0x84] + Array("webm".utf8))
    let mkv = Data(ebml + [0x88] + Array("matroska".utf8))
    XCTAssertEqual(ContentSniffer.type(ofHeader: webm), Formats.webm)
    XCTAssertEqual(ContentSniffer.type(ofHeader: mkv), Formats.mkv)
  }

  func testOpusIsNotMistakenForOgg() {
    let page: [UInt8] = Array("OggS".utf8) + [UInt8](repeating: 0, count: 22) + [1, 19]
    XCTAssertEqual(
      ContentSniffer.type(ofHeader: Data(page + Array("OpusHead".utf8))), Formats.opus)
    XCTAssertEqual(
      ContentSniffer.type(ofHeader: Data(page + Array("\u{1}vorbis".utf8))), Formats.ogg)
  }

  func testAudioOnlyMP4KeepsAudioIdentity() throws {
    let header = Data("\0\0\0\u{18}ftypisom\0\0\u{2}\0".utf8)
    let dir = FileManager.default.temporaryDirectory
    let audio = dir.appendingPathComponent("zest-\(UUID().uuidString).m4a")
    let video = dir.appendingPathComponent("zest-\(UUID().uuidString).mp4")
    try header.write(to: audio)
    try header.write(to: video)
    defer {
      try? FileManager.default.removeItem(at: audio)
      try? FileManager.default.removeItem(at: video)
    }
    XCTAssertEqual(ContentSniffer.type(ofFileAt: audio), .mpeg4Audio)
    XCTAssertEqual(ContentSniffer.type(ofFileAt: video), .mpeg4Movie)
  }

  func testContentBeatsWrongExtension() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-\(UUID().uuidString).jpg")
    try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(ContentSniffer.type(ofFileAt: url), .png)
  }

  func testFallsBackToExtension() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-\(UUID().uuidString).txt")
    try Data("plain".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertEqual(ContentSniffer.type(ofFileAt: url), .plainText)
  }
}
