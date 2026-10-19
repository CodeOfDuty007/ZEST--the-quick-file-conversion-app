import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZestCore

public struct EditColor: Sendable, Equatable {
  public var red: Double, green: Double, blue: Double, alpha: Double

  public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// Built in sRGB explicitly. `CGColor(red:green:blue:alpha:)` uses a generic RGB space,
  /// which shifts the colour when drawn into an sRGB image.
  var cgColor: CGColor {
    CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
  }

  public static let orange = EditColor(1, 0.48, 0)
  public static let red = EditColor(0.96, 0.2, 0.2)
  public static let blue = EditColor(0.1, 0.45, 1)
  public static let green = EditColor(0.2, 0.75, 0.35)
  public static let black = EditColor(0, 0, 0)
  public static let white = EditColor(1, 1, 1)
}

/// A mark drawn on top of an image. Coordinates are image pixels with the origin at the
/// top-left, which is what a canvas view naturally produces.
public struct ImageAnnotation: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case rectangle(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case text(String, at: CGPoint, fontSize: CGFloat)
  }

  public var kind: Kind
  public var color: EditColor
  public var lineWidth: CGFloat

  public init(_ kind: Kind, color: EditColor = .red, lineWidth: CGFloat = 6) {
    self.kind = kind
    self.color = color
    self.lineWidth = lineWidth
  }
}

/// The look of "add a background to a screenshot": a gradient with the shot floating on it.
public struct BackdropStyle: Sendable, Equatable {
  public var top: EditColor
  public var bottom: EditColor
  /// Margin around the image as a fraction of its longer side.
  public var padding: Double
  public var rounded: Bool
  public var shadow: Bool

  public init(
    top: EditColor, bottom: EditColor, padding: Double = 0.1, rounded: Bool = true,
    shadow: Bool = true
  ) {
    self.top = top
    self.bottom = bottom
    self.padding = padding
    self.rounded = rounded
    self.shadow = shadow
  }

  public static let presets: [(name: String, style: BackdropStyle)] = [
    ("Zest", BackdropStyle(top: EditColor(1, 0.7, 0.28), bottom: EditColor(0.95, 0.4, 0.05))),
    ("Ocean", BackdropStyle(top: EditColor(0.3, 0.7, 1), bottom: EditColor(0.1, 0.25, 0.8))),
    ("Dusk", BackdropStyle(top: EditColor(0.75, 0.45, 0.95), bottom: EditColor(0.25, 0.2, 0.6))),
    ("Mint", BackdropStyle(top: EditColor(0.6, 0.95, 0.75), bottom: EditColor(0.1, 0.6, 0.55))),
    ("Graphite", BackdropStyle(top: EditColor(0.45, 0.47, 0.5), bottom: EditColor(0.12, 0.13, 0.15))),
    ("Paper", BackdropStyle(top: EditColor(1, 1, 1), bottom: EditColor(0.9, 0.9, 0.92))),
  ]
}

/// Pure pixel edits for the image editor. Every function takes and returns a `CGImage`, so
/// they are testable without a window.
public enum ImageEditing {
  // MARK: Crop

  /// `rect` is in image pixels, origin top-left. It is clamped to the image.
  public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let clipped = rect.integral.intersection(bounds)
    guard clipped.width >= 1, clipped.height >= 1 else { return nil }
    return image.cropping(to: clipped)
  }

  // MARK: Redact

  /// Burns opaque black over each rectangle. The pixels underneath are replaced, not
  /// covered by a layer, so nothing can be recovered from the result.
  public static func redact(_ image: CGImage, rects: [CGRect]) -> CGImage? {
    guard let context = makeContext(for: image) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setBlendMode(.copy)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for rect in rects {
      context.fill(flipped(rect.integral, height: image.height))
    }
    return context.makeImage()
  }

  // MARK: Annotate

  public static func annotate(_ image: CGImage, items: [ImageAnnotation]) -> CGImage? {
    guard let context = makeContext(for: image) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    for item in items {
      context.setStrokeColor(item.color.cgColor)
      context.setFillColor(item.color.cgColor)
      context.setLineWidth(item.lineWidth)
      switch item.kind {
      case .rectangle(let rect):
        context.stroke(flipped(rect, height: image.height))
      case .arrow(let from, let to):
        drawArrow(in: context, from: flip(from, height: image.height), to: flip(to, height: image.height), width: item.lineWidth)
      case .text(let string, let point, let size):
        drawText(string, in: context, at: flip(point, height: image.height), size: size, color: item.color)
      }
    }
    return context.makeImage()
  }

  private static func drawArrow(in context: CGContext, from: CGPoint, to: CGPoint, width: CGFloat) {
    let angle = atan2(to.y - from.y, to.x - from.x)
    let head = max(width * 3.5, 18)
    let spread = CGFloat.pi / 7
    context.beginPath()
    context.move(to: from)
    context.addLine(to: to)
    context.strokePath()
    context.beginPath()
    context.move(to: to)
    context.addLine(to: CGPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
    context.addLine(to: CGPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
    context.closePath()
    context.fillPath()
  }

  /// `point` is the text's top-left in unflipped (bottom-left origin) coordinates.
  private static func drawText(
    _ string: String, in context: CGContext, at point: CGPoint, size: CGFloat, color: EditColor
  ) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor,
    ]
    let line = CTLineCreateWithAttributedString(
      CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
    context.saveGState()
    // Place the baseline so the text hangs down from the point.
    context.textPosition = CGPoint(x: point.x, y: point.y - CTFontGetAscent(font))
    CTLineDraw(line, context)
    context.restoreGState()
  }

  // MARK: Background

  public static func addBackground(_ image: CGImage, style: BackdropStyle) -> CGImage? {
    let longer = Double(max(image.width, image.height))
    let margin = (longer * style.padding).rounded()
    let width = image.width + Int(margin * 2)
    let height = image.height + Int(margin * 2)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let gradient = CGGradient(
        colorsSpace: space, colors: [style.top.cgColor, style.bottom.cgColor] as CFArray,
        locations: [0, 1])
    else { return nil }

    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    let frame = CGRect(x: margin, y: margin, width: CGFloat(image.width), height: CGFloat(image.height))
    let radius = style.rounded ? CGFloat(min(image.width, image.height)) * 0.025 : 0
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // The shadow is cast by the clipped image itself, inside a transparency layer, so
    // transparent pixels stay transparent and show the gradient instead of a black box.
    context.saveGState()
    if style.shadow {
      context.setShadow(
        offset: CGSize(width: 0, height: -CGFloat(longer) * 0.012), blur: CGFloat(longer) * 0.04,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(shape)
    context.clip()
    context.draw(image, in: frame)
    context.endTransparencyLayer()
    context.restoreGState()
    return context.makeImage()
  }

  // MARK: Export

  /// Writes the image with no metadata at all. Edited pixels no longer match the original's
  /// EXIF, and an embedded thumbnail could still show whatever a redaction removed.
  public static func write(
    _ image: CGImage, as type: UTType, to url: URL, quality: Double = 0.92
  ) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw BackendError.encodeFailed(url.lastPathComponent) }
    var options: [CFString: Any] = [:]
    if type == .jpeg || type == .heic { options[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw BackendError.encodeFailed(url.lastPathComponent)
    }
  }

  // MARK: Helpers

  /// The format a saved edit should use: the source's own, unless it cannot be written.
  public static func saveType(for source: UTType) -> UTType {
    let writable: Set<UTType> = [.png, .jpeg, .heic, .tiff]
    return writable.contains(source) ? source : .png
  }

  private static func makeContext(for image: CGImage) -> CGContext? {
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  private static func flip(_ point: CGPoint, height: Int) -> CGPoint {
    CGPoint(x: point.x, y: CGFloat(height) - point.y)
  }

  private static func flipped(_ rect: CGRect, height: Int) -> CGRect {
    CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
  }
}
