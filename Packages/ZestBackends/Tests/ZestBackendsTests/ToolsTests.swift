import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
import ZestCore

@testable import ZestBackends

class ToolTestCase: XCTestCase {
  var dir: URL!
  let catalog = Catalog()

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-tools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  func tool(_ id: String) throws -> ToolSpec {
    try XCTUnwrap(catalog.router.tools.first { $0.id == id }, "no tool \(id)")
  }

  func files() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
  }

  /// A noisy image, so JPEG and PNG sizes are large enough to compress meaningfully.
  func makeImage(
    _ type: UTType, named name: String, width: Int = 400, height: Int = 300,
    properties: [CFString: Any] = [:], noise: Bool = true
  ) throws -> URL {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise {
      var generator = SystemRandomNumberGenerator()
      for _ in 0..<2500 {
        context.setFillColor(
          CGColor(
            red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
            blue: .random(in: 0...1, using: &generator), alpha: 1))
        context.fill(
          CGRect(
            x: .random(in: 0..<width, using: &generator), y: .random(in: 0..<height, using: &generator),
            width: 12, height: 12))
      }
    }
    let url = dir.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  func makePDF(named name: String, pages: Int, title: String? = nil) throws -> URL {
    let url = dir.appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    var info: [CFString: Any] = [:]
    if let title { info[kCGPDFContextTitle] = title; info[kCGPDFContextAuthor] = "Someone" }
    let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
    for page in 0..<pages {
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(red: 0.2, green: CGFloat(page) / 5, blue: 0.8, alpha: 1))
      context.fill(box)
      context.endPDFPage()
    }
    context.closePDF()
    return url
  }

  func size(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  func properties(_ url: URL) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
  }
}

final class MultiFileConvertTests: ToolTestCase {
  func testMixedHEICAndPNGConvertToJPEGInOneGo() async throws {
    let heic = try makeImage(.heic, named: "photo.heic")
    let png = try makeImage(.png, named: "shot.png")
    let types = try [heic, png].map { try XCTUnwrap(ContentSniffer.type(ofFileAt: $0)) }

    let option = try XCTUnwrap(
      catalog.router.resolve(inputs: types).available.first { $0.output == .jpeg })
    XCTAssertEqual(option.routes.count, 2)

    for (url, route) in zip([heic, png], option.routes) {
      _ = try await catalog.pipeline.run(input: url, route: route)
    }
    XCTAssertEqual(try files(), ["photo.heic", "photo.jpg", "shot.jpg", "shot.png"])
  }

  func testAFileAlreadyInTheTargetFormatBlocksThatFormatForTheMix() {
    // jpg + png → jpg is hidden for the whole selection: the common-subset rule.
    let result = catalog.router.resolve(inputs: [.jpeg, .png])
    XCTAssertFalse(result.available.contains { $0.output == .jpeg })
    XCTAssertEqual(result.rejected.first { $0.output == .jpeg }?.reason, .sameFormat)
  }
}

final class ImageToolTests: ToolTestCase {
  func testCompressJPEGReachesTheTargetSize() async throws {
    let jpeg = try makeImage(.jpeg, named: "big.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.98])
    let before = size(jpeg)
    let report = try await catalog.pipeline.runTool(try tool("compress.image.50"), inputs: [jpeg])
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.lastPathComponent, "big compressed.jpg")
    XCTAssertLessThanOrEqual(size(out), Int(Double(before) * 0.5))
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .jpeg)
    XCTAssertEqual(try files(), ["big compressed.jpg", "big.jpg"])
  }

  func testSmallerTargetsProduceSmallerFiles() async throws {
    let jpeg = try makeImage(.jpeg, named: "p.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.98])
    let light = try await catalog.pipeline.runTool(try tool("compress.image.75"), inputs: [jpeg])
    let strong = try await catalog.pipeline.runTool(try tool("compress.image.25"), inputs: [jpeg])
    XCTAssertLessThan(size(strong.published[0]), size(light.published[0]))
  }

  func testCompressPNGShrinksByScaling() async throws {
    let png = try makeImage(.png, named: "shot.png")
    let report = try await catalog.pipeline.runTool(try tool("compress.image.50"), inputs: [png])
    let out = try XCTUnwrap(report.published.first)
    XCTAssertLessThan(size(out), size(png))
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .png)
  }

  func testCompressNeverMakesAFileLargerAndReportsWhySkipped() async throws {
    let tiny = try makeImage(.png, named: "flat.png", width: 8, height: 8, noise: false)
    let report = try await catalog.pipeline.runTool(try tool("compress.image.25"), inputs: [tiny])
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertEqual(report.skipped.map(\.reason), ["Already small"])
    XCTAssertEqual(try files(), ["flat.png"])
  }

  func testCompressBatchSkipsOnlyTheFilesThatCannotShrink() async throws {
    let big = try makeImage(.jpeg, named: "big.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 0.98])
    let tiny = try makeImage(.png, named: "flat.png", width: 8, height: 8, noise: false)
    let report = try await catalog.pipeline.runTool(try tool("compress.image.50"), inputs: [big, tiny])
    XCTAssertEqual(report.published.map(\.lastPathComponent), ["big compressed.jpg"])
    XCTAssertEqual(report.skipped.map(\.input.lastPathComponent), ["flat.png"])
  }

  private let secrets: [CFString: Any] = [
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ACME", kCGImagePropertyTIFFModel: "Cam 9"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note"],
    kCGImagePropertyGPSDictionary: [
      kCGImagePropertyGPSLatitude: 12.34, kCGImagePropertyGPSLatitudeRef: "N",
      kCGImagePropertyGPSLongitude: 56.78, kCGImagePropertyGPSLongitudeRef: "E",
    ],
  ]

  func testStripRemovesExifGPSAndCameraButKeepsOrientation() async throws {
    let jpeg = try makeImage(.jpeg, named: "phone.jpg", properties: secrets)
    XCTAssertNotNil(properties(jpeg)[kCGImagePropertyGPSDictionary], "fixture must carry GPS")

    let report = try await catalog.pipeline.runTool(try tool("strip.image"), inputs: [jpeg])
    let out = try XCTUnwrap(report.published.first)
    let after = properties(out)
    XCTAssertNil(after[kCGImagePropertyGPSDictionary])
    let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
    XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
    let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
    XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
    // The photo must still display upright.
    XCTAssertEqual(after[kCGImagePropertyOrientation] as? Int, 6)
    XCTAssertEqual(OrientedImage.load(out)?.width, 300)
    XCTAssertEqual(OrientedImage.load(out)?.height, 400)
  }

  func testStripLeavesTheOriginalUntouched() async throws {
    let jpeg = try makeImage(.jpeg, named: "phone.jpg", properties: secrets)
    let before = try Data(contentsOf: jpeg)
    _ = try await catalog.pipeline.runTool(try tool("strip.image"), inputs: [jpeg])
    XCTAssertEqual(try Data(contentsOf: jpeg), before)
  }

  func testStripWorksOnPNGAndHEIC() async throws {
    for (type, name) in [(UTType.png, "a.png"), (.heic, "b.heic")] {
      let url = try makeImage(type, named: name, properties: secrets)
      let report = try await catalog.pipeline.runTool(try tool("strip.image"), inputs: [url])
      let out = try XCTUnwrap(report.published.first, name)
      XCTAssertNil(properties(out)[kCGImagePropertyGPSDictionary], name)
      XCTAssertFalse(ImageToolsBackend.containsPersonalMetadata(at: out), name)
      XCTAssertEqual(ContentSniffer.type(ofFileAt: out), type, name)
      // Upright either way: the tag is kept, or the pixels were rotated.
      XCTAssertEqual(OrientedImage.load(out)?.width, 300, name)
      XCTAssertEqual(OrientedImage.load(out)?.height, 400, name)
    }
  }

  func testCollageTilesEveryImageIntoOneJPEG() async throws {
    let inputs = try (1...3).map { try makeImage(.png, named: "i\($0).png") }
    let report = try await catalog.pipeline.runTool(try tool("collage"), inputs: inputs)
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.lastPathComponent, "i1 collage.jpg")
    // Three images lay out as 2 columns by 2 rows.
    let image = try XCTUnwrap(OrientedImage.load(out))
    XCTAssertEqual(image.width, 2 * 800 + 3 * 16)
    XCTAssertEqual(image.height, 2 * 800 + 3 * 16)
  }

  func testCollageNeedsAtLeastTwoImages() {
    let router = catalog.router
    let collage = router.tools.first { $0.id == "collage" }!
    XCTAssertEqual(router.visibility(of: collage, inputs: [.png]), .hidden(.needsAtLeast(2)))
    XCTAssertEqual(router.visibility(of: collage, inputs: [.png, .heic]), .enabled)
  }
}

final class PDFToolTests: ToolTestCase {
  private func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

  func testMergeKeepsEveryPageInOrder() async throws {
    let a = try makePDF(named: "a.pdf", pages: 1)
    let b = try makePDF(named: "b.pdf", pages: 2)
    let report = try await catalog.pipeline.runTool(try tool("pdf.merge"), inputs: [a, b])
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.lastPathComponent, "a merged.pdf")
    XCTAssertEqual(pageCount(out), 3)
  }

  func testImagesToPDFMakesOnePagePerImage() async throws {
    let inputs = [
      try makeImage(.png, named: "one.png", width: 120, height: 80),
      try makeImage(.jpeg, named: "two.jpg", width: 60, height: 90),
    ]
    let report = try await catalog.pipeline.runTool(try tool("images.to.pdf"), inputs: inputs)
    let out = try XCTUnwrap(report.published.first)
    let document = try XCTUnwrap(PDFDocument(url: out))
    XCTAssertEqual(document.pageCount, 2)
    XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 120, height: 80))
    XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 60, height: 90))
  }

  func testSplitWritesOneFilePerPage() async throws {
    let doc = try makePDF(named: "doc.pdf", pages: 3)
    let report = try await catalog.pipeline.runTool(try tool("pdf.split"), inputs: [doc])
    XCTAssertEqual(
      report.published.map(\.lastPathComponent).sorted(),
      ["doc page 1.pdf", "doc page 2.pdf", "doc page 3.pdf"])
    XCTAssertTrue(report.published.allSatisfy { pageCount($0) == 1 })
  }

  func testPagesToImagesRendersAt150DPI() async throws {
    let doc = try makePDF(named: "doc.pdf", pages: 2)
    let report = try await catalog.pipeline.runTool(try tool("pdf.pages.images"), inputs: [doc])
    XCTAssertEqual(report.published.count, 2)
    let image = try XCTUnwrap(OrientedImage.load(report.published[0]))
    XCTAssertEqual(image.width, Int((200 * 150.0 / 72).rounded()))
    XCTAssertEqual(image.height, Int((100 * 150.0 / 72).rounded()))
  }

  func testStripRemovesTitleAndAuthor() async throws {
    let doc = try makePDF(named: "doc.pdf", pages: 1, title: "Secret plan")
    XCTAssertEqual(PDFDocument(url: doc)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Secret plan")
    let report = try await catalog.pipeline.runTool(try tool("strip.pdf"), inputs: [doc])
    let attributes = PDFDocument(url: try XCTUnwrap(report.published.first))?.documentAttributes
    XCTAssertNil(attributes?[PDFDocumentAttribute.titleAttribute])
    XCTAssertNil(attributes?[PDFDocumentAttribute.authorAttribute])
  }

  func testAFailedBatchLeavesNothingBehind() async throws {
    let good = try makePDF(named: "good.pdf", pages: 1)
    let bad = dir.appendingPathComponent("bad.pdf")
    try Data("not a pdf".utf8).write(to: bad)
    do {
      _ = try await catalog.pipeline.runTool(try tool("pdf.merge"), inputs: [good, bad])
      XCTFail("expected failure")
    } catch {}
    XCTAssertEqual(try files(), ["bad.pdf", "good.pdf"])
  }

  func testPDFToolsAreHiddenForImages() {
    let merge = catalog.router.tools.first { $0.id == "pdf.merge" }!
    XCTAssertEqual(catalog.router.visibility(of: merge, inputs: [.png, .png]), .hidden(.wrongType(.png)))
  }
}

final class AudioVideoToolTests: ToolTestCase {
  private var ffmpeg: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    ffmpeg = try XCTUnwrap(FFmpegBackend.detect()?.executable, "ffmpeg required")
  }

  private func make(_ args: [String], _ name: String) async throws -> URL {
    let url = dir.appendingPathComponent(name)
    try await ProcessRunner.run(
      ffmpeg, arguments: ["-nostdin", "-y", "-loglevel", "error"] + args + [url.path])
    return url
  }

  /// The ffmpeg binary prints stream info to stderr; ffprobe is the clean way to ask.
  private func probe(_ url: URL, _ args: [String]) throws -> String {
    let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
    let process = Process()
    process.executableURL = ffprobe
    process.arguments = args + [url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  func testCompressVideoShrinksIt() async throws {
    let video = try await make(
      ["-f", "lavfi", "-i", "testsrc=size=640x360:rate=24:duration=3", "-c:v", "libx264",
       "-b:v", "6M", "-pix_fmt", "yuv420p"], "clip.mp4")
    let report = try await catalog.pipeline.runTool(try tool("compress.video.50"), inputs: [video])
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.lastPathComponent, "clip compressed.mp4")
    XCTAssertLessThan(size(out), size(video))
    XCTAssertTrue(try probe(out, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0"]).contains("h264"))
  }

  func testCompressAudioShrinksIt() async throws {
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-b:a", "320k"], "tone.mp3")
    let report = try await catalog.pipeline.runTool(try tool("compress.audio.25"), inputs: [audio])
    XCTAssertLessThan(size(try XCTUnwrap(report.published.first)), size(audio))
  }

  func testStripRemovesTagsWithoutReencoding() async throws {
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-metadata", "title=Secret",
       "-metadata", "artist=Someone"], "tagged.mp3")
    XCTAssertTrue(try probe(audio, ["-v", "error", "-show_entries", "format_tags", "-of", "default=nw=1"]).contains("Secret"))
    let report = try await catalog.pipeline.runTool(try tool("strip.av"), inputs: [audio])
    let out = try XCTUnwrap(report.published.first)
    let tags = try probe(out, ["-v", "error", "-show_entries", "format_tags=title,artist", "-of", "default=nw=1"])
    XCTAssertFalse(tags.contains("Secret"))
    XCTAssertFalse(tags.contains("Someone"))
  }

  func testAudioConvertsToVideoWithAVideoStream() async throws {
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"], "song.mp3")
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .mp3, to: .mpeg4Movie))
    let out = try await catalog.pipeline.run(input: audio, route: route)
    XCTAssertEqual(out.lastPathComponent, "song.mp4")
    let streams = try probe(out, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0"])
    XCTAssertTrue(streams.contains("video"))
    XCTAssertTrue(streams.contains("audio"))
  }
}

final class ToolHonestyTests: ToolTestCase {
  func testPublishedExtensionFollowsTheEncodedFormatNotTheFileName() async throws {
    // PNG data wearing a .jpg name: the output must be named for what it contains.
    let png = try makeImage(.png, named: "real.png")
    let liar = dir.appendingPathComponent("photo.jpg")
    try FileManager.default.moveItem(at: png, to: liar)

    let report = try await catalog.pipeline.runTool(
      try tool("compress.image.50"), inputs: [liar])
    let out = try XCTUnwrap(report.published.first)
    XCTAssertEqual(out.pathExtension, "png")
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .png)
  }

  func testStripNamesTheOutputForItsRealFormatToo() async throws {
    let png = try makeImage(.png, named: "real.png")
    let liar = dir.appendingPathComponent("photo.jpg")
    try FileManager.default.moveItem(at: png, to: liar)
    let report = try await catalog.pipeline.runTool(try tool("strip.image"), inputs: [liar])
    XCTAssertEqual(report.published.first?.pathExtension, "png")
  }

  func testEncoderReportsWhenTheTargetIsOutOfReach() throws {
    let url = try makeImage(.jpeg, named: "n.jpg")
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let best = ImageToolsBackend.encodeWithin(source: source, type: .jpeg, targetBytes: 1)
    XCTAssertGreaterThan(best?.count ?? 0, 1, "it returns its best effort; the caller must check")
  }

  func testAnimatedImagesAreNotFlattened() async throws {
    let url = dir.appendingPathComponent("anim.png")
    let context = CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 2, nil)!
    for _ in 0..<2 { CGImageDestinationAddImage(destination, context.makeImage()!, nil) }
    CGImageDestinationFinalize(destination)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 1
    else { throw XCTSkip("this ImageIO cannot write multi-frame PNG") }

    let report = try await catalog.pipeline.runTool(try tool("compress.image.50"), inputs: [url])
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertEqual(report.skipped.count, 1)
  }
}

final class FFmpegTargetTests: ToolTestCase {
  private var ffmpeg: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    ffmpeg = try XCTUnwrap(FFmpegBackend.detect()?.executable, "ffmpeg required")
  }

  private func make(_ args: [String], _ name: String) async throws -> URL {
    let url = dir.appendingPathComponent(name)
    try await ProcessRunner.run(
      ffmpeg, arguments: ["-nostdin", "-y", "-loglevel", "error"] + args + [url.path])
    return url
  }

  func testAudioPercentTargetsTheRequestedSize() async throws {
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=10", "-b:a", "128k"], "tone.mp3")
    for percent in [75, 50, 25] {
      let report = try await catalog.pipeline.runTool(
        try tool("compress.audio.\(percent)"), inputs: [audio])
      let out = try XCTUnwrap(report.published.first, "\(percent)%")
      let ratio = Double(size(out)) / Double(size(audio))
      XCTAssertLessThanOrEqual(ratio, Double(percent) / 100 * FFmpegBackend.sizeTolerance, "\(percent)%")
    }
  }

  func testVideoPercentTargetsTheRequestedSize() async throws {
    let video = try await make(
      ["-f", "lavfi", "-i", "testsrc=size=640x360:rate=24:duration=4", "-c:v", "libx264",
       "-b:v", "4M", "-pix_fmt", "yuv420p"], "clip.mp4")
    let report = try await catalog.pipeline.runTool(try tool("compress.video.50"), inputs: [video])
    let out = try XCTUnwrap(report.published.first)
    let ratio = Double(size(out)) / Double(size(video))
    XCTAssertLessThanOrEqual(ratio, 0.5 * FFmpegBackend.sizeTolerance)
  }

  func testAnUnreachableTargetIsSkippedNotReportedAsDone() async throws {
    // A tiny, already-minimal clip cannot be halved again, and must say so.
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-b:a", "16k"], "low.mp3")
    let report = try await catalog.pipeline.runTool(try tool("compress.audio.25"), inputs: [audio])
    XCTAssertTrue(report.published.isEmpty)
    XCTAssertEqual(report.skipped.count, 1)
    XCTAssertEqual(try files(), ["low.mp3"])
  }

  func testMislabelledAudioKeepsItsRealExtension() async throws {
    let audio = try await make(
      ["-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-b:a", "192k"], "real.mp3")
    let liar = dir.appendingPathComponent("song.m4a")
    try FileManager.default.moveItem(at: audio, to: liar)
    let report = try await catalog.pipeline.runTool(try tool("compress.audio.50"), inputs: [liar])
    XCTAssertEqual(report.published.first?.pathExtension, "mp3")
  }
}
