import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZestCore

@testable import ZestBackends

final class ImageEditingTests: XCTestCase {
  private let red = (r: 255, g: 0, b: 0)
  private let blue = (r: 0, g: 0, b: 255)

  /// 100 x 80 image: the top half is red, the bottom half is blue.
  private func makeImage(width: Int = 100, height: Int = 80) -> CGImage {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CG's origin is bottom-left, so "top half" is the high y values.
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    context.setFillColor(CGColor(colorSpace: srgb, components: [1, 0, 0, 1])!)
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    context.setFillColor(CGColor(colorSpace: srgb, components: [0, 0, 1, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    return context.makeImage()!
  }

  /// RGBA of one pixel, with (0, 0) at the top-left like the editor uses.
  private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4  // memory rows run top to bottom
    return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
  }

  private func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r > 240 && p.g < 15 && p.b < 15 }
  private func isBlue(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.b > 240 && p.r < 15 && p.g < 15 }

  func testFixtureHasRedOnTop() {
    let image = makeImage()
    XCTAssertTrue(isRed(pixel(image, 50, 5)))
    XCTAssertTrue(isBlue(pixel(image, 50, 75)))
  }

  // MARK: Crop

  func testCropTakesTheRequestedTopLeftRegion() throws {
    let cropped = try XCTUnwrap(ImageEditing.crop(makeImage(), to: CGRect(x: 10, y: 0, width: 40, height: 30)))
    XCTAssertEqual(cropped.width, 40)
    XCTAssertEqual(cropped.height, 30)
    XCTAssertTrue(isRed(pixel(cropped, 5, 5)), "a top-left crop of the red half must stay red")
  }

  func testCropAtTheBottomKeepsTheBlueHalf() throws {
    let cropped = try XCTUnwrap(ImageEditing.crop(makeImage(), to: CGRect(x: 0, y: 50, width: 20, height: 20)))
    XCTAssertTrue(isBlue(pixel(cropped, 10, 10)))
  }

  func testCropIsClampedToTheImageAndRejectsEmptyAreas() throws {
    let clamped = try XCTUnwrap(ImageEditing.crop(makeImage(), to: CGRect(x: 80, y: 60, width: 100, height: 100)))
    XCTAssertEqual(clamped.width, 20)
    XCTAssertEqual(clamped.height, 20)
    XCTAssertNil(ImageEditing.crop(makeImage(), to: CGRect(x: 200, y: 200, width: 10, height: 10)))
    XCTAssertNil(ImageEditing.crop(makeImage(), to: .zero))
  }

  // MARK: Redact

  func testRedactBlacksOutOnlyTheRectangle() throws {
    let result = try XCTUnwrap(ImageEditing.redact(makeImage(), rects: [CGRect(x: 10, y: 10, width: 30, height: 20)]))
    let inside = pixel(result, 20, 20)
    XCTAssertEqual([inside.r, inside.g, inside.b, inside.a], [0, 0, 0, 255])
    XCTAssertTrue(isRed(pixel(result, 60, 20)), "outside stays untouched")
    XCTAssertTrue(isRed(pixel(result, 20, 5)), "above the box stays untouched")
    XCTAssertTrue(isBlue(pixel(result, 20, 70)), "the other half stays untouched")
  }

  func testRedactTopLeftAffectsTheTopLeftNotTheBottomLeft() throws {
    let result = try XCTUnwrap(ImageEditing.redact(makeImage(), rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]))
    XCTAssertEqual(pixel(result, 3, 3).r, 0)
    XCTAssertTrue(isBlue(pixel(result, 3, 77)), "the bottom-left corner must be unchanged")
  }

  func testRedactionSurvivesAnExportAndReload() throws {
    let result = try XCTUnwrap(ImageEditing.redact(makeImage(), rects: [CGRect(x: 0, y: 0, width: 100, height: 40)]))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-redact-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try ImageEditing.write(result, as: .png, to: url)
    let reloaded = try XCTUnwrap(OrientedImage.load(url))
    // The whole red half is gone: nothing red remains anywhere.
    for y in stride(from: 0, to: 80, by: 4) {
      for x in stride(from: 0, to: 100, by: 7) { XCTAssertFalse(isRed(pixel(reloaded, x, y)), "\(x),\(y)") }
    }
  }

  // MARK: Annotate

  func testRectangleDrawsAnOutlineAndLeavesTheInside() throws {
    let result = try XCTUnwrap(
      ImageEditing.annotate(
        makeImage(), items: [ImageAnnotation(.rectangle(CGRect(x: 20, y: 10, width: 50, height: 30)), color: .green, lineWidth: 4)]))
    let edge = pixel(result, 20, 25)
    XCTAssertGreaterThan(edge.g, edge.r, "the left edge is drawn in green")
    XCTAssertTrue(isRed(pixel(result, 45, 25)), "the inside is not filled")
  }

  func testArrowMarksItsEndpoint() throws {
    let result = try XCTUnwrap(
      ImageEditing.annotate(
        makeImage(), items: [ImageAnnotation(.arrow(from: CGPoint(x: 10, y: 70), to: CGPoint(x: 80, y: 70)), color: .green, lineWidth: 4)]))
    let tip = pixel(result, 78, 70)
    XCTAssertGreaterThan(tip.g, 150)
    XCTAssertTrue(isBlue(pixel(result, 50, 50)), "away from the arrow is untouched")
  }

  func testTextChangesPixelsNearItsAnchor() throws {
    let base = makeImage(width: 200, height: 100)
    let result = try XCTUnwrap(
      ImageEditing.annotate(base, items: [ImageAnnotation(.text("Zest", at: CGPoint(x: 10, y: 10), fontSize: 30), color: .white)]))
    var changed = 0
    for y in 10..<45 { for x in 10..<90 where pixel(result, x, y).g > 100 { changed += 1 } }
    XCTAssertGreaterThan(changed, 30, "white glyph pixels appear below and right of the anchor")
    XCTAssertEqual(pixel(result, 150, 90).b, 255, "far away stays blue")
  }

  // MARK: Background

  func testBackgroundAddsMarginAndKeepsTheImageInTheMiddle() throws {
    let image = makeImage()
    let result = try XCTUnwrap(ImageEditing.addBackground(image, style: BackdropStyle.presets[0].style))
    let margin = Int((100.0 * 0.1).rounded())
    XCTAssertEqual(result.width, 100 + margin * 2)
    XCTAssertEqual(result.height, 80 + margin * 2)
    XCTAssertTrue(isRed(pixel(result, result.width / 2, margin + 10)))
    XCTAssertTrue(isBlue(pixel(result, result.width / 2, margin + 70)))
    XCTAssertEqual(pixel(result, 2, 2).a, 255, "the backdrop is opaque")
  }

  func testBackgroundGradientRunsTopToBottom() throws {
    let style = BackdropStyle(top: .white, bottom: .black, shadow: false)
    let result = try XCTUnwrap(ImageEditing.addBackground(makeImage(), style: style))
    XCTAssertGreaterThan(pixel(result, 2, 2).r, pixel(result, 2, result.height - 3).r + 150)
  }

  func testTransparentPixelsShowTheGradientNotABlackBox() throws {
    // A fully transparent image: nothing of it should darken the backdrop.
    let context = CGContext(
      data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let clear = try XCTUnwrap(context.makeImage())
    let style = BackdropStyle(top: .white, bottom: .white, shadow: true)
    let result = try XCTUnwrap(ImageEditing.addBackground(clear, style: style))
    let centre = pixel(result, result.width / 2, result.height / 2)
    XCTAssertGreaterThan(centre.r, 240, "transparent pixels must not be filled with black")
  }

  func testOpaqueImagesStillCastAShadow() throws {
    let style = BackdropStyle(top: .white, bottom: .white, shadow: true)
    let result = try XCTUnwrap(ImageEditing.addBackground(makeImage(), style: style))
    let margin = Int((100.0 * 0.1).rounded())
    // Just below the image's bottom edge the white backdrop is darkened by the shadow.
    let below = pixel(result, result.width / 2, margin + 80 + 3)
    XCTAssertLessThan(below.r, 250)
  }

  // MARK: Export

  func testExportCarriesNoMetadata() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zest-meta-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    try ImageEditing.write(makeImage(), as: .jpeg, to: url)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
    XCTAssertFalse(ImageToolsBackend.containsPersonalMetadata(at: url))
  }

  func testSaveTypeFallsBackToPNGForFormatsWeCannotWrite() {
    XCTAssertEqual(ImageEditing.saveType(for: .jpeg), .jpeg)
    XCTAssertEqual(ImageEditing.saveType(for: .heic), .heic)
    XCTAssertEqual(ImageEditing.saveType(for: .gif), .png)
    XCTAssertEqual(ImageEditing.saveType(for: .webP), .png)
  }
}
