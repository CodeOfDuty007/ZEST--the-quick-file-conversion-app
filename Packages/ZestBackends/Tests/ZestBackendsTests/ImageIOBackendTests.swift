import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZestCore

@testable import ZestBackends

final class ImageIOBackendTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-backend-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  /// A synthetic 64x48 PNG, so no binary fixtures live in the repo.
  private func makePNG(named name: String = "sample.png") throws -> URL {
    let context = CGContext(
      data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let url = dir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return url
  }

  private func dimensions(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
  }

  func testDeclaresCommonFormats() {
    let caps = ImageIOBackend().capabilities()
    let outputs = Set(caps.map(\.output))
    XCTAssertTrue(outputs.isSuperset(of: [.jpeg, .png, .tiff]))
    XCTAssertTrue(caps.allSatisfy { $0.isNative })
  }

  func testPNGToJPEGGoldenPath() async throws {
    let source = try makePNG()
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .png, to: .jpeg))
    let out = try await catalog.pipeline.run(input: source, route: route)

    XCTAssertEqual(out.lastPathComponent, "sample.jpg")
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .jpeg)
    let size = try XCTUnwrap(dimensions(out))
    XCTAssertEqual(size.0, 64)
    XCTAssertEqual(size.1, 48)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testPNGToTIFFAndBack() async throws {
    let source = try makePNG()
    let catalog = Catalog()
    let tiff = try await catalog.pipeline.run(
      input: source, route: try XCTUnwrap(catalog.router.bestRoute(from: .png, to: .tiff)))
    XCTAssertEqual(ContentSniffer.type(ofFileAt: tiff), .tiff)
    let back = try await catalog.pipeline.run(
      input: tiff, route: try XCTUnwrap(catalog.router.bestRoute(from: .tiff, to: .png)))
    XCTAssertEqual(back.lastPathComponent, "sample 2.png")
  }

  func testUnreadableFileFailsCleanly() async throws {
    let bogus = dir.appendingPathComponent("bogus.png")
    try Data("not an image".utf8).write(to: bogus)
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .png, to: .jpeg))
    do {
      _ = try await catalog.pipeline.run(input: bogus, route: route)
      XCTFail("expected failure")
    } catch {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["bogus.png"])
  }
}

final class ImageFormatExpansionTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-expand-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  private func makeImage(_ type: UTType, named name: String) throws -> URL {
    let context = CGContext(
      data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
    let url = dir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return url
  }

  func testPNGToPDFProducesOnePageOfTheSameSize() async throws {
    let png = try makeImage(.png, named: "page.png")
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .png, to: .pdf))
    let out = try await catalog.pipeline.run(input: png, route: route)

    XCTAssertEqual(out.lastPathComponent, "page.pdf")
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .pdf)
    let document = try XCTUnwrap(CGPDFDocument(out as CFURL))
    XCTAssertEqual(document.numberOfPages, 1)
    let box = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
    XCTAssertEqual(box.width, 80)
    XCTAssertEqual(box.height, 60)
  }

  func testHEICReachesPDFAndTheWheelOffersIt() throws {
    let router = Catalog().router
    XCTAssertTrue(router.resolve(inputs: [.heic]).available.contains { $0.output == .pdf })
  }

  func testPNGToWebPGoldenPath() async throws {
    guard WebPBackend.detect() != nil else { throw XCTSkip("cwebp not installed") }
    let png = try makeImage(.png, named: "pic.png")
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .png, to: .webP))
    let out = try await catalog.pipeline.run(
      input: png, route: route, params: ["quality": "70"])
    XCTAssertEqual(out.lastPathComponent, "pic.webp")
    XCTAssertEqual(ContentSniffer.type(ofFileAt: out), .webP)
  }

  func testHEICToWebPGoesThroughALosslessHop() throws {
    guard WebPBackend.detect() != nil else { throw XCTSkip("cwebp not installed") }
    let route = try XCTUnwrap(Catalog().router.bestRoute(from: .heic, to: .webP))
    XCTAssertEqual(route.hops, 2)
    XCTAssertTrue(route.steps[0].isLosslessOutput)
  }

  func testPNGOffersImageDocumentAndTextOutputs() {
    let outputs = Catalog().router.resolve(inputs: [.png]).available.map(\.output)
    XCTAssertTrue(outputs.contains(.pdf))
    XCTAssertTrue(outputs.contains(Formats.markdown))
    XCTAssertTrue(outputs.contains(.html))
    XCTAssertLessThanOrEqual(outputs.count, 12, "\(outputs)")
  }
}

final class OrientationTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-orient-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  /// An 80x60 JPEG tagged EXIF orientation 6, which a viewer shows as 60x80.
  private func makeRotatedJPEG() throws -> URL {
    let context = CGContext(
      data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
    let url = dir.appendingPathComponent("phone.jpg")
    let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      dest, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return url
  }

  private func size(_ url: URL) throws -> (Int, Int) {
    let image = try XCTUnwrap(OrientedImage.load(url))
    return (image.width, image.height)
  }

  func testOrientedLoadSwapsDimensions() throws {
    let size = try size(makeRotatedJPEG())
    XCTAssertEqual(size.0, 60)
    XCTAssertEqual(size.1, 80)
  }

  func testRotatedJPEGBecomesAnUprightPDFPage() async throws {
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .jpeg, to: .pdf))
    let out = try await catalog.pipeline.run(input: try makeRotatedJPEG(), route: route)
    let page = try XCTUnwrap(CGPDFDocument(out as CFURL)?.page(at: 1))
    let box = page.getBoxRect(.mediaBox)
    XCTAssertEqual(box.width, 60)
    XCTAssertEqual(box.height, 80)
  }

  func testRotatedJPEGBecomesAnUprightWebP() async throws {
    guard WebPBackend.detect() != nil else { throw XCTSkip("cwebp not installed") }
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .jpeg, to: .webP))
    let out = try await catalog.pipeline.run(input: try makeRotatedJPEG(), route: route)
    let size = try size(out)
    XCTAssertEqual(size.0, 60)
    XCTAssertEqual(size.1, 80)
  }

  func testNormalizationLeavesNoStagingFileBehind() async throws {
    guard WebPBackend.detect() != nil else { throw XCTSkip("cwebp not installed") }
    let catalog = Catalog()
    let route = try XCTUnwrap(catalog.router.bestRoute(from: .jpeg, to: .webP))
    _ = try await catalog.pipeline.run(input: try makeRotatedJPEG(), route: route)
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    XCTAssertEqual(files, ["phone.jpg", "phone.webp"])
  }
}
